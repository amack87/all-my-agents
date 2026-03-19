# All My Agents - Claude Code Project Instructions

## Build & Test

```bash
./build.sh              # Full build (release)
./build.sh debug        # Debug build
swift build -c release  # Compile only (no bundle assembly)
```

No test suite exists yet. Verify changes by building and manually testing in the app.

## Key Constraints

- **tmux 3.6a crash**: NEVER use `new-session -t` (grouped sessions). Always use `attach-session`. Grouped sessions trigger a use-after-free in `server_destroy_session_group`. See TerminalSession.swift comments.
- **Swift concurrency**: Use `DispatchQueue.global` (not async Task) for running `Process` objects that do blocking I/O. Swift's cooperative thread pool deadlocks when all threads block on `waitUntilExit()`.
- **Immutability**: All state updates must create new objects. Never mutate arrays or models in place. See NotificationStore's copy/upsert patterns.
- **tmux-attach-helper**: Required because SwiftTerm uses `POSIX_SPAWN_SETSID` without `TIOCSCTTY`. The C helper establishes a controlling terminal before exec'ing tmux. Must be compiled and placed in `Contents/MacOS/`.

## Architecture Overview

- **NotificationStore** (`NotificationStore.swift`) - Central `@Observable` singleton. All state lives here: notifications, sessions, speedrun state machine, sidebar preferences.
- **SessionMonitor** (`Services/SessionMonitor.swift`) - 1-second polling loop. Discovers Claude sessions via `ps`, maps to tmux panes, detects status from `capture-pane` output.
- **WebhookServer** (`Services/WebhookServer.swift`) - NWListener on port 9876. Receives agent status updates as JSON POST requests.
- **TerminalSession** (`Services/TerminalSession.swift`) - Manages SwiftTerm attachment to tmux via `attach-session` and `tmux-attach-helper`.
- **SpeedrunView** (`Views/SpeedrunView.swift`) - Complex state machine for cycling through agents. Auto-advances when agents start working after user input.

## Speedrun State Machine

```
.idle → .viewing(id) → .advancing → .viewing(next) or .switching(from, to)
                     → .switching(from, to) → .viewing(to)
                     → .allWorking → touring .viewing(id)
```

- `.viewing`: Embedded terminal shown, capture-pane polling active
- `.switching`: 3-second countdown overlay with keyboard controls
- `.advancing`: Brief transition while resolving next agent
- `.allWorking`: All agents busy, transitions to touring mode

## Status Detection (SessionMonitor + SpeedrunView)

Pane content analysis heuristics:
- **Working**: "esc to interrupt", progress indicators ("Computing...", "Reading..."), no prompt
- **Needs Input**: "esc to cancel", numbered options (1. 2.), "Y/n" prompts, "?" endings
- **Idle**: `❯` prompt visible with no active signals
- Prompt absence requires 3 consecutive polls to confirm (guards against autocomplete/slash popups)

## Related: All My Agents Mobile

The companion mobile/web interface is a separate Node.js project (All My Agents-Mobile). It provides remote access to tmux sessions via browser/phone over Tailscale.

- **Port**: 3456 (HTTP + WebSocket)
- Can be run standalone (`node server.js`) or as a launchd agent
- If using launchd with `KeepAlive`, always use `launchctl stop/start` — never `kill`

## Optional: claude-hibernator

Both this app and All My Agents-Mobile optionally integrate with `claude-hibernator` for session hibernation/restore. Set the `HIBERNATOR_CLI` env var to the path of `cli.py` to enable. Without it, the "Restore Hibernated" feature is hidden/disabled gracefully.

## File Size Guidelines

Most files are 100-300 lines. SpeedrunView.swift (~670 lines) and SessionMonitor.swift (~500 lines) are the largest. If either grows beyond 800 lines, extract subsystems.
