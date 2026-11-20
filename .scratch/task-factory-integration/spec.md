# PRD: All My Agents knows about task groups, working directories and agent messages

Status: ready-for-agent
Tracker: this repository, `.scratch/task-factory-integration/`

Task Factory gives each captured task its own agent, and that agent is an All My Agents session.
This PRD is the All My Agents side of that: the server can carry a session's group and working
directory, the sidebar shows task sessions together, and a chat panel lets James talk to an
agent and approve things from a phone.

## Problem Statement

All My Agents knows a session's name, status, agent and task — but nothing about where the
session is working or which group it belongs to. Both are now needed:

Task Factory starts each task's agent in the task's own folder and puts it in a `Task Factory`
group, so that a dozen task agents do not scatter through the sidebar. It also needs to reach
James — and to carry an approval decision that only James can give — through a surface that
works on a phone.

Today the sidebar's group membership is a property of a browser's local copy, pushed to the
server. A second surface cannot join a session to a group, and nothing can declare that a
session belongs somewhere. There is also no chat panel: the web app shows a terminal, and the
agent's messages are published by the API but rendered by nobody.

## Solution

Make the server the authority on group membership and working directory, and give both clients a
chat panel that renders agent messages and sends replies.

A session declares the group it belongs to and the folder it works in when it is created. The
server owns both, publishes them with the session everywhere it publishes a session, and carries
them through a restart. The sidebar groups task sessions together, ordered by the user's manual
order as before.

The chat panel renders the agent's messages as they arrive, lets James reply by typing, and
marks where a message came from — because a reply from the panel and a reply typed into a
terminal are not the same kind of thing.

## User Stories

### Group membership

1. As James, I want a session to declare the group it belongs to, so that a program can put a session somewhere without a browser.
2. As James, I want every task agent to appear together under one `Task Factory` group, so that twelve of them are not scattered through my sidebar.
3. As James, I want a group to keep its members across a server restart, so that a restart does not scatter my work.
4. As James, I want to drag a tile out of a group, so that I can tidy the sidebar by hand.
5. As James, I want my order inside a group preserved when membership changes, so that a new member does not reshuffle the rest.
6. As James, I want the server and the browser to agree on membership, so that two surfaces never show different groups.
7. As James, I want the group a session belongs to shown on the tile, so that I can see why it is where it is.
8. As James, I want to know which groups are server-declared and which are mine, so that I do not fight the app over a tile's home.

### Working directory

9. As James, I want a session to be created in a given folder, so that the agent starts where the work is.
10. As James, I want that folder to survive a restart, so that a restored session resumes in the same place.
11. As James, I want the folder visible in the session's details, so that I know where an agent is working.
12. As James, I want a session created without a folder to behave exactly as before, so that nothing else changes.

### Chat panel

13. As James, I want to read an agent's messages in a panel beside the terminal, so that I do not have to read terminal output.
14. As James, I want to reply to an agent by typing in the panel, so that I can talk to it from a phone.
15. As James, I want each message to say which session it came from, so that I know who is talking.
16. As James, I want the panel to show messages as they arrive, so that I see a reply without refreshing.
17. As James, I want the panel to work for any session, not only task sessions, so that it is a tool and not a Task Factory feature.
18. As James, I want to see which sessions are waiting on me, oldest wait first, so that I can work through my backlog.
19. As James, I want the panel to mark where a message came from, so that I can tell a panel reply from something typed into a terminal.
20. As James, I want the panel's replies to be identifiable by anything that consumes them, so that an approval can be trusted to come from me.

### Compatibility

21. As James, I want the contract to state what changed, so that a client can tell an old server from a new one.
22. As James, I want the existing clients to keep working against a new server, so that the upgrade is not a coordinated event.
23. As James, I want a behaviour both apps must agree on to be written down once and tested twice, so that the two surfaces cannot drift.

## Implementation Decisions

- **The server owns group membership.** A session carries the group it belongs to; the server
  publishes it wherever it publishes a session. This amends ADR-0006: the sidebar-groups store
  keeps order, collapsed state and the ungrouped order, but no longer holds membership. (ADR-0017)
- **Group membership is not an agent-authored field.** A session's group and state are declared by
  the server and cannot be written through the agent event route, unlike the agent's own
  description of its work.
- **A session's state travels with it**: a server-owned value describing where the task is —
  grilling, spec ready, awaiting approval, executing, done, failed, parked. It is distinct from
  status (what the agent is doing now) and from the task description (the agent's own words).
- **Session creation accepts an optional working directory and an optional group.** The server
  already starts a session's pane in a given folder; the public route did not expose it.
- **A restored session keeps its folder, its group and its state**, recorded with the rest of the
  restore registry.
- **Dragging a tile into or out of a group is a server write**, because membership is the server's
  to declare. Ordering within a group remains the user's manual order.
- **The published contract moves to the next version**, with the new session fields, and the
  change is written into the shared contract fixture with a case asserted by both test suites.
- **The chat panel renders messages that already arrive.** The agent event hook already publishes
  the agent's text; the panel is the missing half. The panel lists a session's messages newest
  last, with the session name, and has a composer that sends to the session.
- **Message origin is tagged.** A message sent from the panel carries the panel's origin; text
  typed into a terminal does not. A consumer that needs to know whether a message came from
  James reads the origin.
- **The panel's message list is a cursor over a short-lived store.** The store is in memory and
  empty after a restart; the durable record of a conversation belongs to whoever owns the task.
- **"Needs you" is a view, not a coordinator.** It is the list of sessions in a group whose
  status says they are waiting on input, ordered by how long they have been waiting. Nothing
  changes because of it.
- **The panel is general.** It is not scoped to Task Factory and knows nothing about tasks.

## Testing Decisions

A good test here asserts what a person can observe: which group a session appears in, which
folder a session starts in, what the panel shows, and where a message came from. Tests that
assert internal bookkeeping prove nothing about the behaviour and break on every refactor.

**Seams, highest first:**

- **The shared contract fixture.** Any behaviour the two apps must agree on gets one case in the
  shared fixture, asserted by both suites — the rule this repository already follows. The new
  session fields, the group's appearance on a tile and the two clients' agreement on membership
  are all contract cases.
- **The session creation route.** A created session starts in the requested folder, carries the
  requested group, and a request without either behaves exactly as before.
- **The sidebar's rendering of membership.** Given sessions and a group store, which tiles are in
  which group, in which order — asserted once per client, from the shared fixture.
- **The panel's message list and composer.** Which messages appear, in what order, with what
  origin, and what a reply does.
- **The restore path.** A restarted session comes back with its folder, its group and its state.

**Prior art:** the shared contract fixture and its two asserting suites already exist in this
repository; the sidebar's group resolution is already covered by a fixture with winner cases.

## Out of Scope

- A macOS-app chat panel. V1 builds the panel in the web app; the macOS app is a later step and
  the contract carries what it needs.
- Any voice interface. All My Agents grows no voice surface of its own.
- Task Factory's own logic: the ledger, the gate, the watcher and the dispatcher are its
  repository's work.
- Ordering inside a group decided by the server. Order stays the user's.
- Any behaviour that lets an agent set its own group or state.
- Durable message history in All My Agents. The panel shows a short-lived copy; the record of
  record belongs to the task's owner.

## Further Notes

The two clients must not drift: the shared fixture is the contract, and the change to it is the
change to the public surface. The contract version moves with it, so a client can tell what it
is talking to.

The trust distinction the panel introduces — a message from James in the panel versus text typed
into a terminal — is worth keeping small and explicit. All My Agents records where a message came
from; it does not decide what that means. The consumer decides, and Task Factory is the first.
