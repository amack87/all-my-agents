# 3 — The chat panel and "Needs you"

Part of: .scratch/task-factory-integration/spec.md
Status: done — branch `issue/03-the-chat-panel-and-needs-you`
Labels: feature

## What to build

A way to talk to an agent that is not the terminal. The agent's messages already arrive through
the API; nobody renders them. The panel is the missing half: it sits beside the terminal, lists
the session's messages newest last with the session's name, updates as they arrive, and has a
composer that sends James's reply to the session.

Where a message came from matters. A reply typed in the panel is James; text typed into a
terminal is not, and a consumer must be able to tell the difference — Task Factory will trust a
panel reply and nothing else. So the origin travels with the message.

And a list of who is waiting on James: the sessions in a group whose status says they need input,
oldest wait first. It is a view. Nothing happens because of it.

The panel is a tool, not a Task Factory feature: it works for any session and knows nothing about
tasks.

## Acceptance criteria

- [ ] An agent message appears in the panel without a refresh
- [ ] The panel lists a session's messages newest last, each showing which session it came from
- [ ] A reply typed in the panel reaches the agent, and comes back marked as from the panel
- [ ] Text typed into a terminal comes back without that mark, and a consumer of the message route can tell the two apart
- [ ] The panel works for a session that belongs to no group
- [ ] "Needs you" lists exactly the sessions in a group whose status is `needsInput`, oldest wait first
- [ ] Nothing changes because of the "Needs you" list — it is a view
- [ ] The macOS app is not part of this; the contract carries what it will need

## Blocked by

1 — the server owns a session's group and directory
