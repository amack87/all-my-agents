# 3 — Extracted reconciler + unit tests

Part of: .scratch/session-reconciliation/spec.md
Status: ready-for-agent
Labels: enhancement
Source: GitHub issue #4 (amack87/all-my-agents) — https://github.com/amack87/all-my-agents/issues/4
> **Migrated from [amack87/all-my-agents-web#4](https://github.com/amack87/all-my-agents-web/issues/4).**
> The web app now lives in `web/` in this monorepo, so file paths below are relative to the monorepo root.

## Parent

#1

## What to build

Extract the per-machine session reconciliation logic from `loadSessions()` into a standalone pure function in its own module. Write unit tests that verify the function's behavior without any DOM or network dependencies.

**Extracted function signature:**
```
reconcileMachineSessions(
  existing: { [name]: { sessions, lastSeen } },
  incoming: { machines: { [name]: { status, sessions } } },
  now: number,
  staleMs: number = 300000
) => { machineSessions: { [name]: { sessions, lastSeen } }, sessions: Array<Session> }
```

**Behavior:**
- For each machine in `incoming.machines` with `status: "ok"`: replace its entry with the fresh sessions and `now`
- For each machine with `status: "error"`: keep its existing entry if present, do nothing if absent
- Prune machines where `now - lastSeen > staleMs`
- Return the updated `machineSessions` map plus a flat, sorted `sessions` array
- Sorting order: needsInput (0) > working (1) > idle (2) > unknown (3), then most recent activity first

**Tests (Node.js assert, no framework):**
- Session replacement when machine returns OK
- Session preservation when machine returns error
- Session preservation when machine is absent from response
- Pruning when machine exceeds staleMs
- Sorting by status priority and activity
- Empty inputs (no existing, no incoming)
- Multiple machines interacting correctly

## Acceptance criteria

- [ ] `reconcileMachineSessions()` is extracted as a pure function in its own module
- [ ] The function is imported and used in `loadSessions()` to drive the reconciliation
- [ ] All 7 test cases pass: replacement, error preservation, absent preservation, pruning, sorting, empty, multiple machines
- [ ] No DOM, network, or module-level state touched by the function or tests
- [ ] Existing reconciliation behavior in `loadSessions()` is unchanged (refactoring only)

## Blocked by

- #2
