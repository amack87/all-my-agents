# 15. Agent task state is local-first, stored in the macOS app

Date: 2026-11-17
Scope: macos

## Status

Accepted

## Context

Session status (`working`, `idle`, `needsInput`, …) is provided by the web server's mesh aggregation, which aggregates status from multiple sources:

1. **Screen-scraped status** — tmux `capture-pane` analysis, performed server-side
2. **Event-derived status** — agents POST to `/api/events` with `status: working|idle|needsInput`

Status tells the user *whether* an agent is busy, not *what* it is doing. A session can be `working` for hours on one task and `working` on another task minutes later — the status does not change, but the work has.

So the user wants:

- the **current task** an agent is pursuing ("Fixing login bug", "Running CI tests"), next to the status
- task **transitions** to be detectable, so the user knows an agent started something new
- task state to display correctly for **peer** sessions, even though it originates on another machine
- existing sessions without task state to still display normally

## Decision

Task state is stored **in the macOS app**, fed from the server's event stream. The app is a **client** of the server's task channel (ADR-0016): the server relays, the app holds.

- **`ClaudeSession.task`** — a new optional field on the session model
  (`Sources/AgentHub/Models/ClaudeSession.swift`), carrying the task text the server last
  reported for that session. `nil` means "no task reported".
- **Filled from the mesh snapshot** — `MeshAPIClient.MeshSession.task` is decoded from
  `/api/mesh/sessions` and from the `/ws/status` feed, and `mapSessions` puts it on the
  `ClaudeSession`. The HTTP poll and the WebSocket feed share one mapper, so they cannot
  disagree about the task.
- **Held in `NotificationStore`** — `NotificationStore.sessions` is the app's single source of
  truth for sessions, so the task rides with the session it belongs to. The store is
  in-memory: nothing about the task is written to disk.
- **Rendered in the sidebar** — `SessionRowView` shows the task as a dimmed caption under the
  agent line, truncated to one line. SwiftUI's `Text` renders a `String` verbatim, so no
  markup in a task can become formatting or content.
- **One task per session** — the task belongs to the session (the tmux pane), not to an agent
  inside it. Two agents in the same pane report against the same slot and the last report
  wins.

The app never persists the task. It is re-read from the server on the next snapshot, so a task
survives an **app** restart for as long as the **server** is still running (the server holds
the last reported task in memory; see ADR-0016 for what happens when the server restarts).

## Alternatives considered

#### A. Persist task state to disk in the macOS app

**Rejected for now**: the task is a live signal, not a record. Persisting it invites a second
source of truth (a stale file disagreeing with the live server) for no user-visible gain. It
remains the obvious answer if task history is ever wanted.

#### B. Screen-scrape the task from the pane, in the app

**Rejected**: the app does not scrape panes today — status detection lives on the server and
is imperfect enough already. A second scraper would produce a second, disagreeing notion of
what an agent is doing.

## Consequences

#### Positive

- The app holds no task-specific machinery: the field rides the existing session pipeline.
- A task change reaches every device watching the mesh — the server pushes it, and the feed
  signature includes it, so a task-only change is actually pushed (ADR-0016).

#### Negative

- **Agents must report it.** An agent that never sends `task` shows a blank task line.
- **No history.** The app holds the current task, not a list of tasks.
- **One task per pane.** Two agents sharing a tmux pane share one task slot.
- **Lost on server restart.** The server's registry is in memory; until the agent reports
  again, the task is blank.

## Implementation Checklist

- [x] `ClaudeSession.task` added (`Sources/AgentHub/Models/ClaudeSession.swift`)
- [x] `MeshSession.task` decoded and mapped (`Sources/AgentHub/Services/MeshAPIClient.swift`)
- [x] Task rendered in the sidebar row (`Sources/AgentHub/Views/SessionSidebarView.swift`)
- [x] Shared fixture with hostile inputs read by this suite
      (`Tests/AllMyAgentsTests/TaskContractTests.swift`)

## Related

- ADR: `docs/adr/0016-web-server-task-pass-through.md` (the server's side of the channel)
- ADR: `docs/adr/0006-groups-are-protected.md` (the other rule the two apps must agree on,
  and the precedent for a shared fixture in `contract/`)
