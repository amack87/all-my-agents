# 14. The terminal has a fixed dark palette

Date: 2026-11-16
Scope: macos

## Status

Accepted

## Context

Terminals in the macOS app sometimes rendered with a white background, with the agent's chat panel painted white from edge to edge. The panes at fault were the ones running opencode; Claude Code panes stayed dark.

The cause was not opencode's theme, and not tmux. An agent running inside a terminal asks the terminal for its background colour over OSC 11 (`ESC ] 11 ; ? BEL`) at startup and picks a theme to match. opencode's default theme mode is `system`, so the answer decides what the pane looks like.

AMA's terminals are SwiftTerm views, and both terminal paths set their colours from the macOS system colours:

```swift
view.nativeForegroundColor = .textColor
view.nativeBackgroundColor = .textBackgroundColor
```

`.textBackgroundColor` is a *dynamic* colour: it is white in a light-appearance window and near-black in a dark one. SwiftTerm resolves a dynamic colour when it is set, so the value baked into the terminal was whatever the appearance was at that moment. In a light-mode window the terminal answered OSC 11 with white, opencode picked its light theme, and the pane turned white.

Two things follow from the mechanism. The answer comes from whatever is attached to the tmux pane: the browser's xterm.js never answers OSC 11, so the web app already resolves a dark theme and needs no change. The macOS app's SwiftTerm view is what answered, and it was answering with the host appearance.

Measured, with a pty harness answering OSC 11 with a chosen colour: a white answer makes opencode paint `#FFFFFF` / `#FAFAFA` / `#F5F5F5` — byte-identical to the white panes; a black answer makes it paint `#0A0A0A` / `#141414` / `#1E1E1E`. The same holds for a resumed session.

The palette is re-read at runtime, not only at startup. A running opencode re-queries the terminal and repaints its panel when the terminal changes size — a resize sends the process a `SIGWINCH`, and the repaint uses the colour the terminal answers then. Observed after the fix was shipped: panes whose opencode processes predated the change repainted from the light palette to the dark one, with the same cell counts and new colours, and without the agent process restarting.

## Decision

Every terminal AMA paints uses one fixed palette, whatever the macOS appearance is:

- background `#0A0A0A`
- foreground `#E6E6E6`

The colours live in `TerminalPalette` (`Sources/AgentHub/Utilities/TerminalPalette.swift`), and both terminal paths call `TerminalPalette.apply(to: view)`: the local tmux attachment (`TerminalSession`) and the remote WebSocket proxy (`WebSocketTerminalSession`).

Both colours are pinned, not just the background. `.textColor` is dynamic too, so leaving it following the appearance would put near-black text on the fixed dark background in a light-mode window.

The background is `#0A0A0A` because that is the colour opencode's own dark theme paints, so the agent's panel and the terminal's background meet without a seam.

Setting `nativeBackgroundColor` also sets the terminal's own background colour, which is what SwiftTerm answers OSC 11 with. One call therefore fixes both what the user sees and what the agent believes — there is no second mechanism to keep in step.

## Alternatives considered

- **Keep following the macOS appearance and give the terminal a fixed dark background only in its rendering.** Rejected: the terminal would still answer OSC 11 with the appearance's background, so an agent in a light-mode window would still paint its light theme over the pane. The rendering and the answer are the same setting in SwiftTerm; fixing one without the other fixes nothing that was reported.
- **Pin the theme in opencode's own configuration** (`theme` in `~/.config/opencode/opencode.json`). Rejected: it fixes one agent on one machine, in a file the user does not think of as part of the app, and does nothing for the terminal itself. The other agents in the pane would still read a white background.
- **Answer OSC 11 with a colour of our own, independent of the terminal.** Rejected: SwiftTerm's default already answers with the terminal's background colour, and the terminal's background is the thing the user actually sees. A separate OSC 11 override would be a second source of truth for one number.

## Consequences

- The app's terminals look the same in a light and a dark macOS appearance. That is the point, but it does mean a user in a light-mode window gets dark terminals.
- A pane that is already running an agent re-reads the palette the next time its terminal resizes, so it repaints from the light palette to the dark one without the agent restarting. A pane that is never resized keeps the palette it resolved until it is.
- opencode in a tmux pane attached to the browser is unaffected — the browser's terminal never answers OSC 11, so the agent already resolves a dark theme there.
- `TerminalPaletteTests` pins the two colours and asserts that they resolve to the same value under the light and dark appearances, so the palette cannot quietly become dynamic again.
