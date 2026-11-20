# PRD: Incremental session reconciliation with per-machine state

Status: ready-for-agent
Labels: enhancement
Source: GitHub issue #1 (amack87/all-my-agents) — https://github.com/amack87/all-my-agents/issues/1
> **Migrated from [amack87/all-my-agents-web#1](https://github.com/amack87/all-my-agents-web/issues/1).**
> The web app now lives in `web/` in this monorepo, so file paths below are relative to the monorepo root.

## Problem Statement

When the session list refreshes, all sessions temporarily disappear from the screen while the server aggregates responses from every mesh peer. If any peer is slow or unresponsive (e.g., M4 running sequential `discoverSessions()`), the entire session list stays blank or stale-looking until every peer has responded or timed out. The user cannot interact with existing sessions during this window.

Worse, on every refresh the frontend wholesale-replaces `state.sessions`, causing the UI to flicker, session cards to re-render unnecessarily, and active terminals to temporarily lose their position context.

## Solution

Change the session loading model from "pull everything, then replace everything" to "reconcile per-machine, preserve existing until confirmed gone":

- The server returns sessions grouped by machine, not flattened
- The frontend maintains a per-machine session map as the source of truth
- On refresh, each machine's sessions are only replaced when that machine explicitly confirms its full list (`status: "ok"`)
- If a machine errors or times out, its last-known sessions are preserved unchanged
- Unseen machines are pruned after a grace period (5 min)
- The flat session list for rendering is rebuilt from the reconciled per-machine data
- Optional: per-machine loading indicators (subtle pulse on peer status badges during refresh)

## User Stories

1. As a user with multiple machines in the mesh, I want sessions from a slow peer to remain on screen even when that peer hasn't responded yet, so that I can continue working without disruption.

2. As a user in a terminal session, I want the session list to refresh without causing the active session card to flicker or re-render, so that the UI stays stable during polling.

3. As a user who disconnected from a machine, I want that machine's sessions to stay visible for a grace period (5 min), so that I can still click into them if the machine comes back online.

4. As a user whose machine is slow (e.g., M4 with sequential session discovery), I want my sessions to appear on other mesh nodes even if my machine's response is delayed, so that other users see my sessions as soon as I finish processing.

5. As a user watching the peer status bar, I want to see a visual indicator that a refresh is in progress for each machine, so that I know the system is working and my old sessions are still valid only temporarily.

6. As a developer, I want the reconciliation logic to be a pure function with no DOM or network side effects, so that I can unit test it without mocking the browser or server.

7. As a user who opens the app on phone after a long absence, I want the mesh sessions that were previously visible to stay until a fresh refresh confirms them, so that I don't see an empty list during the first slow poll.

## Implementation Decisions

### Decision 1: Per-machine response shape from server

The `GET /api/mesh/sessions` endpoint now returns machines grouped by name instead of a flat list:

```json
{
  "machines": {
    "MBA M1": { "status": "ok", "sessions": [...] },
    "MBP M4": { "status": "error", "sessions": [] }
  },
  "peerStatus": {
    "MBP M4": "error: timeout"
  }
}
```

- The `machines` map keys are machine names (from mesh config identity)
- `status: "ok"` means the machine confirmed its complete session list
- `status: "error"` means the machine could not be reached — preserve its old sessions
- Each session object is the same shape as before (name, paneId, status, agent, machine, machineHost, lastActivity, etc.)

### Decision 2: Per-machine Frontend State

A new `state.machineSessions` map in web/public/app.js replaces `state.sessions` as the source of truth:

```
state.machineSessions = {
  "MBA M1": { sessions: [...], lastSeen: 1712345678000 },
  "MBP M4": { sessions: [...], lastSeen: 1712345677000 }
}
```

- `state.sessions` becomes a derived/computed property rebuilt from `state.machineSessions`
- Sorting (needsInput first, then working, then idle/unknown, by most recent activity) happens during the rebuild

### Decision 3: Reconciliation Algorithm (pure function candidate)

```
function reconcileMachineSessions(existing, incoming, now, staleMs = 300000):
  merged = copy(existing)
  
  for each (name, machineData) in incoming.machines:
    if machineData.status == "ok":
      merged[name] = { sessions: machineData.sessions, lastSeen: now }
    else:
      // keep existing sessions for errored machines
      if merged[name] exists:
        merged[name].lastSeen = now  // update timestamp so we don't prune
  
  for each (name, ms) in merged:
    if now - ms.lastSeen > staleMs:
      delete merged[name]
  
  flat = flatten(merged).sort(status then lastActivity desc)
  return { machineSessions: merged, sessions: flat }
```

Key invariants:
- Sessions are never removed unless the owning machine sent `status: "ok"`
- An errored/unresponsive machine keeps its last-known sessions indefinitely (until the 5 min stale prune)
- A machine absent from the response entirely also keeps its sessions (it wasn't reachable at all)

### Decision 4: Per-machine Loading State (optional)

During refresh, set a `refreshing: true` flag on each non-local machine entry. The peer status bar renders a subtle pulsing animation on refreshing machines. `refreshing` resets to `false` once the response is processed per-machine. This gives visual feedback without hiding any sessions.

### Decision 5: No SSE Streaming (for now)

Initial implementation uses the existing request/response cycle with per-machine reconciliation. True streaming (SSE where each machine's results arrive as they complete) would eliminate aggregate latency entirely but adds significant complexity (server-sent events, connection management, partial state updates). The per-machine reconciliation already solves the core UX problem — sessions don't disappear during refresh. SSE can be added as a follow-up if poll latency remains an issue after the M4 gets the parallelization fix.

### Modules Modified

1. **web/mesh.js** — `fetchAllMeshSessions()` rewritten to return `{ machines, peerStatus }`
2. **web/public/app.js** — Added `state.machineSessions`, rewritten `loadSessions()`, new `rebuildSessions()` helper
3. **style.css** — Optional: `.peer-indicator.refreshing` animation for loading state

### Modules Potentially Extracted

4. **web/session-reconciler.js** — Pure function `reconcileMachineSessions(existing, incoming, now, staleMs)` extracted from `loadSessions()`. Single-input-single-output no-DOM-no-network pure function. Only extracted if tests are desired.

## Testing Decisions

- Tests should verify the reconciliation function's behavior, not the networking or DOM updates
- A good test: given existing machineSessions and incoming machines data, verify the output matches expectations for: replacement on ok, preservation on error, pruning after staleMs, sorting
- Only the extracted pure function (module 4) should be tested — the inlined version in loadSessions is too coupled to the DOM and network to unit test effectively
- Prior art: there are no existing tests in the repo. First tests should be straightforward assert-based Node.js tests without a test framework

## Out of Scope

- SSE/WebSocket streaming for real-time per-machine results (deferred)
- UI redesign of the session list (the per-machine reconciliation is invisible to the user)
- Fixing the M4's slow `discoverSessions()` (already fixed by parallelization in a separate change)
- Automatic reconnection to timed-out peers (already handled by 3s polling loop)

## Further Notes

- The M4 must pull the latest parallelization fix and restart its AMA server before its `/api/sessions` stops timing out. Until then, the M4's sessions will appear stale (gracefully preserved by the reconciliation logic rather than causing a blank screen).
- This change is backward-compatible with the old frontend — the old `result.sessions` field is no longer returned, but the frontend is updated simultaneously.
