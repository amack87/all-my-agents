# All My Agents - Claude Code Project Instructions

## Build & Test

```bash
./build.sh              # Full build (release)
./build.sh debug        # Debug build
swift build -c release  # Compile only (no bundle assembly)
```

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test --enable-swift-testing
cd web && node --test
```

The Swift tests use **swift-testing** (`import Testing`), not XCTest — this machine has no Xcode and therefore no `XCTest.framework`. `--enable-swift-testing` is required. The `TestingMacros` plugin occasionally fails to resolve ("plugin for module 'TestingMacros' not found"); re-run, or force it:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test --enable-swift-testing \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

## Repository Layout

This repo is a **monorepo** for two apps that share one server and one set of contracts:

| Path | What it is |
|---|---|
| `Sources/`, `Tests/`, `Package.swift`, `build.sh`, `Info.plist` | The macOS app (Swift/SwiftUI). Stays at the repo root — the build is unchanged. |
| `web/` | The web app + its Node server (`web/server.js`, `web/public/`, `web/test/`). Its own `package.json`; tests run with `node --test`. Merged in via `git subtree` (see commit `2b63506`), so its history is preserved. |
| `contract/` | **Shared contract fixtures** — canonical cases consumed by BOTH test suites. |

The macOS app is a *client* of the web server: it polls `/api/mesh/sessions`, creates sessions through `POST /api/sessions`, and syncs sidebar groups via `/api/sidebar-groups`. The server owns session creation, the active-session registry (session restore), and the launch specs.

**Anti-drift rule**: any behaviour the two apps must agree on gets a case in `contract/` and a test in both suites (`Tests/AllMyAgentsTests/ContractTests.swift` and `web/test/contract.test.js`). Do not add the same rule twice in two languages — add the case to the fixture and assert both sides resolve it identically. This is the fix for the sidebar-group bug (web ADR 0006 existed; the macOS app never got the rule).

**SDK workaround (required on this dev machine)**: the Command Line Tools 27.0 toolchain does not ship the `SwiftUIMacros` plugin (and no Xcode is installed), so a plain `swift build` fails on every SwiftUI file with `plugin for module 'SwiftUIMacros' not found`. Point the build at the 26.5 SDK:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./build.sh
```

`-Xswiftc -sdk …` is ignored (SwiftPM injects its own `-sdk` afterwards); use `SDKROOT=` or `swift build --sdk …`. Workaround is only for building here — the resulting app is unaffected.

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

## The Web App (web/)

The web app lives in `web/` and is the **server** the macOS app talks to.

- **Port**: 3456 (HTTP + WebSocket)
- Runs standalone (`node web/server.js`) or as a launchd agent. The installed agent now points at `/Users/andy/Repos/all-my-agents/web` (it used to point at the standalone `all-my-agents-web` checkout).
- If using launchd with `KeepAlive`, always use `launchctl stop/start` — never `kill`
- It owns: session creation (`POST /api/sessions`), the active-session registry and boot-time restore (`~/.local/state/all-my-agents/active-sessions.json`), launch specs, mesh aggregation (`/api/mesh/sessions`), and the surface-token scheme that makes agent status event-sourced instead of screen-scraped.

The separate All My Agents-Mobile project (also Node) is unrelated to `web/` — it is the phone/browser remote interface.

## Optional: claude-hibernator

The **macOS app** integrates with `claude-hibernator` for session hibernation/restore and drives the CLI itself (`HibernatorService`, `BackupService`) — the web app has no hibernation concept. Set the `HIBERNATOR_CLI` env var to the path of `cli.py` to enable. Without it, the hibernation settings show a warning and the restore feature is hidden/disabled gracefully.

## File Size Guidelines

Most files are 100-300 lines. SpeedrunView.swift (~670 lines) and SessionMonitor.swift (~500 lines) are the largest. If either grows beyond 800 lines, extract subsystems.
