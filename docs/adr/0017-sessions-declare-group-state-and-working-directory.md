# 17. Sessions declare their group, their task state and their working directory

Date: 2026-11-19
Scope: system

## Status

Accepted

## Context

Task Factory — a separate project that turns spoken tasks into agents — needs every task it
starts to appear in All My Agents as an ordinary session, sitting in a group of its own, showing
where the task has got to, and running in the task's own directory.

Three gaps stand in the way.

**Working directory.** `POST /api/sessions` takes `{name, command, target}`. The launch machinery
already knows about a directory: `launchPane` passes `dir` into `buildLaunchArgs`, which becomes
`tmux new-session -c <dir>`, and the boot-time restore already records a session's directory and
re-enters it. But the public route never passes one. A session can only start wherever the
server's own working directory happens to be.

**Group.** Group membership is a browser-owned fact. It lives in `sidebar-groups.json`, the web
app keeps a copy in `localStorage` and pushes it, the macOS app keeps a copy in `UserDefaults`,
and the surfaces merge by `pickWinner` (ADR 0006). Nothing that is not a client — another
server, a script, Task Factory — can say "this session belongs to that group" without editing
the user's document.

**Task state.** A session's `status` says whether the *agent* is busy. The `task` field is the
*agent's* own words ("Email Dana Q3"). Neither says where a multi-step workflow has got to:
grilling, awaiting approval, done.

The third gap carries a trap. The obvious way to carry workflow state is to write it into the
agent-authored `task` field. That field has exactly one writer today — the session's surface
token — and a second writer would mean the last writer wins, with the sidebar showing whichever
agent spoke most recently.

## Decision

### 1. `POST /api/sessions` accepts `dir` and `group`

`dir` is an absolute path. It is passed to `launchPane` so the pane starts there, and recorded
in the active-session registry so a restored session returns to it. `group` names the group the
session joins.

Both are optional. A session created without them behaves exactly as it does today.

### 2. Membership becomes server-declared; order stays the user's

The session shape gains a **`group`** field, and it is the authority on which group a session is
in.

`sidebar-groups.json` keeps what is genuinely the user's — the **order** of the groups, the
**collapsed** flags, and the **ungrouped order**. Its `groups` map (group name → session keys)
stops being a source of truth: membership is read from the sessions themselves.

This **amends ADR 0006**. That ADR's protection — a copy with no groups can never erase a copy
that has them — existed because membership was client-owned, so a stray copy could destroy the
user's arrangement. Membership is no longer client-owned and is no longer at risk from a copy.
What ADR 0006 protects from here on is the group's existence and its order. `pickWinner` keeps
its job over those fields, and `groupsCleared` goes with the membership it described.

Dragging a tile into or out of a group becomes a **server write**: the client asks the server to
change that session's `group`. Where a tile sits *within* a group remains the user's, stored as
before.

### 3. The session shape gains `state`, and it is not the agent's to write

`state` is a short string saying where the task's workflow stands: `grilling`, `spec_ready`,
`issues_ready`, `awaiting_approval`, `executing`, `done`, `failed`, `parked`. It is `null` for a
session with no workflow.

Three fields, three different questions, three different writers:

| Field | Question | Writer |
|---|---|---|
| `status` | Is the agent busy? | AMA, from the session's status events |
| `task` | What is the agent doing, in its own words? | the agent, via its surface token |
| `state` | Where is the workflow? | the workflow's owner, through the server's API |

Only the server's own API may write `group` or `state`. The events channel (`POST /api/events`)
does not accept them, so a surface token cannot set them — a session's agent cannot put itself
into a group or declare itself finished.

### 4. The contract declares it: version 6 → 7

`contract/api-contract.json` gains `group` and `state` on `session`, `meshSession` and the
`/ws/status` snapshot. The shared fixture gains cases for both fields, asserted in **both**
suites — the anti-drift rule applies, and these are exactly the fields a client would otherwise
quietly ignore.

### 5. Restore keeps them

The active-session registry records `group` and `state` alongside the directory, so a session
restored at boot comes back in its group, with its state, in its directory.

## Alternatives considered

#### A. Keep membership client-owned and let Task Factory edit the store

**Rejected**: it puts a third writer into a last-writer-wins document, and it re-creates the
exact failure ADR 0006 was written about — a copy arriving out of turn erasing the user's
arrangement. The whole point of the groups file is that it is the user's document.

#### B. Carry workflow state in the agent's `task` field

**Rejected**: two writers, one field, and the sidebar shows whichever wrote last. The agent's
words and the workflow's position are different facts.

#### C. Give AMA a first-class task concept — a tasks table, a tasks route

**Rejected for now**: AMA's job is to show sessions. The task's record — spec, issues, approvals,
transcript — belongs to Task Factory's own database. `state` is a label on a session, not a
second domain for AMA to own. If AMA ever needs the task's history, that is a different ADR.

#### D. A dedicated "tasks" section in the sidebar rather than a group

**Rejected**: a group is what the sidebar already has, and it composes with ordering and
collapse for free. A parallel section would be the same idea implemented twice.

#### E. Group membership only for task sessions, client-owned groups untouched

**Rejected**: two membership systems in one sidebar means a tile's group is answered differently
depending on which rule applies to it, and a tile could appear in two places. One rule for all
sessions is simpler to explain and simpler to keep correct.

## Consequences

- AMA's published contract changes: **version 7**. Both clients, and any API consumer, must
  accept the new fields.
- A tile's group is the same on every surface, because membership now comes from one place. The
  sync race that ADR 0006 was written to survive no longer has anything to lose.
- A session that ends leaves no membership behind: membership lives on the session, so it
  disappears with it — which is the opposite of what Task Factory wants, and Task Factory says so
  explicitly by keeping the session alive.
- ADR 0006's protection narrows to the group list and the order. Its `groupsCleared` flag
  becomes meaningless and is dropped.
- The web app and the macOS app both change how they render membership. This is the largest
  single piece of AMA work in this change, and it lands in both clients.

## Implementation Checklist

- [ ] `POST /api/sessions` accepts optional `dir` and `group`; `dir` reaches `launchPane` and the
      active-session registry
- [ ] `session` carries `group` and `state` on `/api/sessions`, `/api/mesh/sessions` and
      `/ws/status`
- [ ] `POST /api/events` does not accept `group` or `state`
- [ ] `sidebar-groups.json` keeps order, collapsed and ungrouped order; its `groups` map is no
      longer authoritative
- [ ] the web app and the macOS app render membership from the session list
- [ ] dragging a tile into or out of a group is a server write
- [ ] the contract is at version 7, with fixture cases read by both suites
- [ ] the restore path records and re-applies `group` and `state`

## Related

- ADR: `docs/adr/0001-manual-sidebar-order.md` (the ordering authority, unchanged)
- ADR: `docs/adr/0006-groups-are-protected.md` (amended by this ADR)
- ADR: `docs/adr/0015-agent-task-state-local-first.md` and
  `docs/adr/0016-web-server-task-pass-through.md` (the agent's own task field)
