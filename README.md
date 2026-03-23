# AllMyAgents

A macOS app for monitoring and managing multiple Claude Code agent sessions running in tmux. Provides a unified UI with webhook notifications, embedded terminals, session discovery, and speedrun mode for rapidly cycling through agents that need your input.

## Features

- **Session Discovery** - Automatically finds running Claude Code sessions via process monitoring and tmux introspection
- **Status Detection** - Detects whether agents are working, need input, or are idle by analyzing tmux pane content
- **Webhook Notifications** - HTTP endpoint (port 9876) for agents to report status changes
- **Embedded Terminal** - View and interact with tmux sessions directly in the app via SwiftTerm
- **Speedrun Mode** - Rapidly cycle through waiting agents with auto-advance, keyboard shortcuts, and a 3-second switching overlay
- **Sidebar Management** - Hide/show sessions, create new tmux sessions, re-add existing ones
- **Menu Bar + Dock** - Status bar icon with waiting count badge, dock badge

## Requirements

- macOS 14+
- tmux (Homebrew or system)
- Accessibility permission (for window activation)

## Build & Run

```bash
./build.sh           # release build (default)
./build.sh debug     # debug build
open AgentHub.app    # launch
```

The build script compiles Swift sources, the `tmux-attach-helper` C binary, assembles the `.app` bundle with icon, and signs with ad-hoc signature.

## Architecture

```
Sources/
  AgentHub/
    AgentHubApp.swift           # Entry point, NSApplication delegate, menu bar
    NotificationStore.swift     # Central @Observable state (notifications, sessions, speedrun)
    Models/
      AgentNotification.swift   # Webhook/tmux notification with status
      ClaudeSession.swift       # Discovered Claude session metadata
    Services/
      SessionMonitor.swift      # 1s polling: ps + tmux → session discovery + status detection
      TerminalSession.swift     # SwiftTerm attachment to tmux sessions
      TmuxHelpers.swift         # Tmux binary resolution + async command execution
      WebhookServer.swift       # NWListener HTTP server on port 9876
      WindowActivator.swift     # AXSwift accessibility for raising windows
      SidebarPreferences.swift  # Persistent hidden-session storage
    Views/
      FloatingPanelRootView.swift   # Top-level router (list / terminal / speedrun)
      SessionSidebarView.swift      # Left sidebar with session list
      NotificationListView.swift    # Main notification list + controls
      SpeedrunView.swift            # Agent cycling UI with auto-advance
      TerminalContainerView.swift   # NSViewRepresentable wrapping SwiftTerm
      AddSessionSheet.swift         # Create/pick tmux session modal
      FloatingPanel.swift           # NSPanel with frame persistence
      ScrollableTerminalView.swift  # Mouse wheel → tmux escape sequences
    Utilities/
      FontFactory.swift         # Terminal font with Unicode fallback cascade
      ShellHelpers.swift        # Generic async process runner
  tmux-attach-helper.c          # C helper: setsid + TIOCSCTTY → exec tmux
```

## Data Flow

1. **Session discovery**: `SessionMonitor` polls `ps` every second, maps TTYs to tmux panes, enriches from `~/.claude/projects/*/sessions-index.json`, detects status via `capture-pane`
2. **Webhook notifications**: Agents POST to `http://localhost:9876/webhook` with JSON payload, `WebhookServer` upserts into `NotificationStore`
3. **Terminal attachment**: `TerminalSession` uses `tmux attach-session` (not grouped sessions) via `tmux-attach-helper` to establish a controlling terminal for SwiftTerm
4. **Speedrun auto-advance**: Polls `capture-pane` to detect when an agent starts working after user input, then shows a 3-second switching overlay before advancing to the next waiting agent

## Speedrun Mode

Keyboard shortcuts while in speedrun:
- **Tab** - Skip to next agent (shows switching overlay)
- **Enter** - Proceed immediately (during switching overlay)
- **Esc** - Go back to previous agent (during switching overlay)

Auto-advance triggers:
- "esc to interrupt" detected (strong working signal)
- Prompt disappears after user presses Enter (content change + prompt absence)
- 3 consecutive polls without prompt (guards against autocomplete popups)

When all waiting agents are handled, speedrun enters **touring mode** (cycles through all agents).

## Webhook API

```bash
# Notify AgentHub that an agent needs input
curl -X POST http://localhost:9876/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "my-agent",
    "session_name": "project-x",
    "status": "waiting_for_input",
    "message": "Need approval to deploy",
    "tmux_pane": "%3"
  }'
```

Status values: `waiting_for_input`, `completed`, `error`

## Key Design Decisions

- **`attach-session` over `new-session -t`**: Grouped sessions trigger a use-after-free crash in tmux 3.6a's `server_destroy_session_group` path. Using `attach-session` adds a client to the existing session without creating groups.
- **`tmux-attach-helper` C binary**: SwiftTerm's subprocess path uses `POSIX_SPAWN_SETSID` without `TIOCSCTTY`, so the child has no controlling terminal. The helper calls `setsid()` + `TIOCSCTTY` before exec'ing tmux.
- **Immutable state**: All data updates in `NotificationStore` create new arrays/objects, never mutate in place.
- **DispatchQueue for tmux commands**: Uses `DispatchQueue.global` instead of Swift concurrency tasks to avoid cooperative thread pool deadlocks when running synchronous process I/O.

## Configuration

- **Sidebar preferences**: `~/.config/agenthub/sidebar-preferences.json` (hidden session names)
- **Window frame**: Persisted via `UserDefaults` key `AgentHubPanelFrame`

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (>=1.11.2) - Terminal emulation
- [AXSwift](https://github.com/tmandry/AXSwift) (>=0.3.0) - macOS Accessibility API
