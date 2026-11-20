# 1 — The server owns a session's group and directory

Part of: .scratch/task-factory-integration/spec.md
Status: done — branch `issue/01-server-owns-group-and-directory`
Labels: feature

## What to build

A session can say which group it belongs to and which folder it works in, and the server is the
one that says it. Today a session's group is a property of one browser's copy of the sidebar,
which means no program can place a session anywhere. Task Factory needs exactly that.

So: creating a session accepts an optional working directory and an optional group. The server
publishes both wherever it publishes a session — the sessions list, the mesh snapshot and the
status frame. A restored session comes back with its folder and its group, because the restore
registry already carries the rest of the session's identity.

This amends ADR-0006: membership moves onto the session, and the sidebar store keeps order,
collapsed state and the ungrouped order. The published contract moves to the next version, with
the new fields written into the shared fixture and asserted by both suites.

## Acceptance criteria

- [ ] Creating a session with a directory and a group succeeds, and the session carries both
- [ ] Creating a session with neither behaves exactly as before — no regression for existing callers
- [ ] The sessions list, the mesh snapshot and the status frame all publish the group and the directory
- [ ] The session's directory is where the pane actually starts
- [ ] A restored session comes back with its directory and its group
- [ ] The shared contract fixture gains a case for the new fields, asserted by the Swift suite and the Node suite
- [ ] The contract version moves on, and the change is recorded in the fixture
- [ ] A session cannot set its own group or directory through the agent event route

## Blocked by

None - can start immediately

## Done

Implemented on `issue/01-server-owns-group-and-directory` (3 commits). `POST /api/sessions`
accepts optional `dir` and `group`; membership is server-declared and carried by the registry
across a restart; the sessions list, the mesh snapshot and the `/ws/status` frame publish
`group` and `dir`; `POST /api/events` refuses `group`/`dir`/`state`. The contract is at
version 7 with the new fields in `contract/api-contract.json` and one case in
`contract/session-fields.json`, asserted by both suites. ADR 0006 is amended as ADR 0017
describes: the synced sidebar store drops `groupsCleared`. Sidebar rendering and drag
behaviour are unchanged (ticket 2). Known transient gap until ticket 2: because the erasure
flag is gone, deleting a surface's last group no longer propagates through the sync.
