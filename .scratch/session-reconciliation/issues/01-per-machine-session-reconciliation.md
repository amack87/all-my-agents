# 1 — Per-machine session reconciliation

Part of: .scratch/session-reconciliation/spec.md
Status: ready-for-agent
Labels: enhancement
Source: GitHub issue #2 (amack87/all-my-agents) — https://github.com/amack87/all-my-agents/issues/2
> **Migrated from [amack87/all-my-agents-web#2](https://github.com/amack87/all-my-agents-web/issues/2).**
> The web app now lives in `web/` in this monorepo, so file paths below are relative to the monorepo root.

## Parent

#1

## What to build

Change the session loading model from "pull all sessions from all peers, flatten, replace" to "return sessions grouped by machine, reconcile per-machine in the frontend, preserve existing sessions unless the machine confirms they're gone."

**Server side:** `GET /api/mesh/sessions` returns `{ machines: { [name]: { status, sessions } }, peerStatus }` instead of a flat `{ sessions, peerStatus }`. On error/timeout, the machine entry has `status: "error"` and empty sessions.

**Frontend:** A new `state.machineSessions` map (`{ [name]: { sessions, lastSeen } }`) becomes the source of truth for session data. `state.sessions` is a derived property rebuilt from `state.machineSessions`. When the mesh response arrives, the reconciler:

- For each machine with `status: "ok"` → replace that machine's sessions unconditionally
- For each machine with `status: "error"` → keep its existing sessions untouched
- After reconciliation, prune machines whose `lastSeen` is older than 5 minutes
- Rebuild the flat `state.sessions` array with sort order (needsInput first, then working, then idle/unknown, by most recent activity)

When the mesh endpoint itself fails entirely, fall back to updating just the local machine's sessions while preserving all remote machine sessions.

The reconciliation algorithm:
```
for each (name, machineData) in response.machines:
  if machineData.status == "ok":
    machineSessions[name] = { sessions: machineData.sessions, lastSeen: now }
  # on error: do nothing — keep existing

now = Date.now()
for each (name, ms) in machineSessions:
  if now - ms.lastSeen > 300_000:
    delete machineSessions[name]

sessions = flatten(machineSessions).sort(status priority, lastActivity desc)
```

## Acceptance criteria

- [ ] `GET /api/mesh/sessions` returns `{ machines, peerStatus }` with per-machine groups
- [ ] When a peer times out, its previously-known sessions remain in the session list
- [ ] When a peer responds with an OK status, its session list is replaced with the new data
- [ ] Machines not seen for 5+ minutes have their sessions pruned from the list
- [ ] Sorting (needsInput > working > idle > unknown, then by most recent activity) is preserved
- [ ] Fallback path works: when mesh endpoint fails, local machine sessions update while remote sessions from all machines are preserved
- [ ] No session flicker during polling — existing session cards stay in the DOM unless explicitly replaced

## Blocked by

None - can start immediately
