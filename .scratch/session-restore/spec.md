# PRD: Automatic session restore at login (continuous registry + native opencode resume)

Status: ready-for-agent
Labels: enhancement
Source: GitHub issue #5 (amack87/all-my-agents) — https://github.com/amack87/all-my-agents/issues/5
> **Migrated from [amack87/all-my-agents-web#5](https://github.com/amack87/all-my-agents-web/issues/5).**
> The web app now lives in `web/` in this monorepo, so file paths below are relative to the monorepo root.

## Problem Statement

After the machine is restarted, the opencode conversations that were running are not automatically restored. Today every recovery is manual: the user has to find the session id and type `opencode -s <id>` by hand. The automation that exists (`tmux-agent-hibernator`) barely works and is built around the wrong mechanism:

- It restores by `opencode export --sanitize` → context-file → `opencode import`, a lossy snapshot copy of state opencode already owns permanently in its own database.
- Its last restore run recovered **2 of 20** sessions, and failed silently (exit 0, log-only): 18 rows pointed at context files that no longer existed.
- It can't survive a hard power-off at all: hibernation only runs on `SIGTERM`, so a sudden power loss produces nothing to restore.
- Bare `opencode` relaunch does **not** continue the last session (observed 2026-09-01 after an interrupted turn) — it opens a fresh conversation, which reads as "I lost my session".

The persistence is not the problem — opencode keeps every conversation continuously in `opencode.db` (4.2 GB, WAL). The problem is that nothing reconnects the tmux pane to that conversation automatically.

## Solution

On login, every managed agent session that was active at last shutdown comes back automatically:

- tmux sessions are recreated in their recorded project directories,
- each pane launches `opencode -s <last-session-id>` so the full conversation (including unprocessed queued messages) is restored exactly as it was.

This is powered by a **continuous registry** maintained by the AMA web server: on every observed change it writes the live set of managed sessions to a state file. Restore-at-boot replays that file inside `web/server.js` startup. Because the registry is always current rather than written at exit, it survives hard power-off; opencode's own database provides the durable conversation state.

Backup, context-export, and the third-party hibernator library are removed entirely.

## User Stories

1. As a user, when I restart my machine, I want every agent session that was running at last shutdown to come back automatically, so that I never have to hunt for session ids again.
2. As a user, when the machine loses power unexpectedly, I want all sessions to still be restorable on next boot, so that a power cut costs me nothing.
3. As a user, I want the restored opencode pane to contain the *full* conversation (same session id), not a sanitized summary of it, so that nothing I said or asked is lost.
4. As a user, when a restored session's conversation id is no longer resolvable, I want the pane to fall back to `opencode -c` in the recorded project directory, so that the agent still comes back to the right project instead of a blank screen.
5. As a user, I want restore failures to be loud in the server logs, so that a partial restore is never silently swallowed.
6. As a user, I want an already-running session (server restarted mid-work via KeepAlive) to be reconciled back into the registry without restarting tmux or the conversation.
7. As a user, I want ad-hoc tmux sessions I create casually to be left alone, so that only agents managed by AMA are auto-restored.
8. As a user, I want the restore to run as part of the server's own startup, so that there is no separate launchd agent whose ordering and environment silently depend on luck.
9. As a user, I want the "hibernate on shutdown" and "hourly backup" features gone, so that the codebase stops pretending a shutdown snapshot is the source of truth.
10. As a user, I want the web UI to stop offering per-session "restore" against a broken hibernator backend, so I am not presented with a control that mostly fails.

## Implementation Decisions

- **Model = continuous registry, not shutdown snapshot.** The server keeps the live set of managed sessions in memory and writes it to `~/.local/state/all-my-agents/active-sessions.json` on every change (add/update/remove), recording `{ tmux name, project dir, opencode session id, agent, firstSeen, lastActive }`.
- **Registry schema (prototype):**
  ```
  { "version": 1, "updatedAt": "<iso>",
    "sessions": [
      { "tmux": "ama-stuff", "dir": "/Users/andy/Repos/all-my-agents-web",
        "sessionId": "ses_...", "agent": "build",
        "firstSeen": "<iso>", "lastActive": "<iso>" }
    ] }
  ```
- **Full rip of `tmux-agent-hibernator`.** The repo is frozen/archived. It is removed from the launchd environment (`HIBERNATOR_CLI`) and both plists. The hourly-backup feature and its settings are dropped entirely.
- **Restore runs inside `web/server.js` startup.** After a settle delay, web/server.js reads the registry and produces an ordered action manifest. This reuses the web plist's existing `WorkingDirectory`, `PATH`, `RunAtLoad`, `KeepAlive`, so ordering and PATH problems vanish. The separate `com.allmyagents-restore.plist` is unloaded and deleted.
- **Resume-plan (prototype):**
  ```
  [ { "kind": "create-tmux", "name": "ama-stuff", "dir": "..." },
    { "kind": "launch-opencode", "name": "ama-stuff", "dir": "...",
      "cmd": ["opencode", "-s", "ses_..."] } ]
  ```
  A registry entry whose session id does not resolve at boot degrades to `["opencode", "-c"]` run in the recorded project dir.
- **Every AMA-managed opencode pane launches as `opencode -s <id>`**, never bare `opencode`, so panes are self-restoring by construction.
- **Discovery stays thin in web/server.js** (ps scan + `GET /session/status` per `--port`, already proven) and feeds the pure registry reconciler. It is integration-verified against the real server, not unit-tested.
- **Managed scope** = tmux sessions hosting an opencode TUI (the current `activeSessionTargets` semantics). Ad-hoc tmux sessions are excluded.
- **Existing UI/backend removal:** `GET /api/hibernated-sessions`, `POST /api/hibernated-sessions/:name/restore`, `POST /api/sessions/:name/hibernate`, and the settings fields `backup` / `shutdownHibernate` are removed; the restore/hibernate buttons are removed from the UI.
- The restore reconciler here and the refresh-time reconciler in PRD #1 remain **separate modules** — no forced merge.

## Testing Decisions

- **What makes a good test:** only external behavior of the pure modules — given observed live sessions + last-known registry + clock, assert the resulting registry diff and the resulting restore manifest. No mocks of tmux/opencode/network; those live behind the thin executor.
- **`web/session-registry.js` (pure, the one real seam):** `reconcileRegistry(live, existing, now) -> { registry, changed, removed }`. All add/update/keep/prune and tmux-pane→session-id mapping logic lives here with zero side effects. Unit-tested with `node:test` (a small script addition to web/package.json; no new framework).
- **`web/restore-plan.js` (pure):** `buildRestorePlan(registry, resolvable) -> actions[]`. The boot-degrade rule (resolvable `sessionId` → `-s`, otherwise `-c` fallback) is a testable branch here.
- **Executor side effects** (tmux/opencode process spawning, state-file writes, discovery polls) live in web/server.js as thin code and are not unit-tested.
- **Prior art:** none in-repo yet (repo has no test runner today); the convention of extracting a pure reconciler ahead of tests is set by PRD #1's `web/session-reconciler.js` precedent.

## Out of Scope

- Cross-machine restore coordination (each machine restores its own local sessions at its own boot; the mesh only reflects live sessions).
- tmux-resurrect / continuum integration, and restoration of non-agent tmux sessions (pane layouts, arbitrary shells).
- Any streaming/SSE UI work and the rest of the session-picker UI.
- Back-compat with the hibernator DB or context files (features being removed).

## Further Notes

- opencode natively persists every conversation to `opencode.db` (WAL) as it happens; unprocessed queued user messages survive a SIGINT + resume (proven 2026-09-01). The plan leans on that instead of snapshotting.
- Evidence the old path was broken: the login restore log shows `Restored 2 of 20 session(s)`; the shutdown hook relied on uncommitted PID-resolution code; a fresh `opencode` launches a blank conversation even when a prior session exists in the same directory.
- The hibernator repo is frozen but not deleted, so its tmux/opencode discovery snippets remain available as reference for the executor.
