# 12. Superwhisper is retired from AMA; AMA will do its own voice

Date: 2026-11-13
Scope: system

## Status

Accepted

## Context

AMA shipped a per-session Superwhisper gate (`web/integrations/opencode/superwhisper-optin.js`). It was a thin layer over the third-party `@superwhisper/opencode` plugin: the plugin decides whether to notify by asking whether `/tmp/superwhisper-agent/disabled-<session id>` exists, so AMA wrote that file to mute a session and deleted it to unmute. The gate muted every session by default, because the third-party plugin notifies by default and AMA's users had ten sessions and wanted one to be noisy.

It was never the thing the user wanted. "Continuous voice mode with my agents" means the microphone is always open and the agents hear you, without a per-session toggle, without a slash command typed into one agent's terminal, and without the other agents staying deaf. A per-session mute gate is the opposite of that: it is a per-session toggle that mutes by default.

Reading the installed Superwhisper app (3.1.0) also showed the integration was incidental rather than structural. The app has its own agent protocol — `superwhisper://agent-installed`, `agent-update`, `agent-wake`, `agent-dismiss`, `agent-hook`, `agent-inbox` — and knows Claude Code, Codex, Cursor, Gemini and OpenCode natively. It dictates into the focused application, with push-to-talk and no always-listening mode. The piece AMA wanted was the opposite of the piece Superwhisper offers.

## Decision

Superwhisper is no longer part of AMA. Nothing in this repository integrates with it, depends on it, or documents it.

- `web/integrations/opencode/superwhisper-optin.js` and its test are deleted. ADR 0008's rule about exporting a plugin's default still holds for the status adapter; the Superwhisper gate it also described is gone.
- The web README no longer documents installing the plugin, copying the gate, or registering the `enable-superwhisper` / `disable-superwhisper` commands.
- The installed copies are removed from the user's environment too: the gate in `~/.config/opencode/plugin/`, the `@superwhisper/opencode` entry in `~/.config/opencode/opencode.json`, and the two slash commands in that file. Removing the gate alone would leave new sessions unmuted and therefore suddenly audible through a third-party app the user had decided to stop using.
- AMA will provide its own always-listening voice mode. The design of that mode is a separate decision, recorded separately.

## Alternatives considered

- **Keep the gate and add a continuous mode on top of it.** Rejected: the gate's whole purpose is to decide when an agent may speak, and continuous voice mode is the absence of that decision. The two cannot coexist in one agent process without one of them winning.
- **Keep Superwhisper as the microphone and only replace the notification side.** Rejected: Superwhisper's dictation is push-to-talk and pastes into the focused application. There is no always-listening mode to switch on, so "continuous" would have to mean "press a key each time" — the thing the user explicitly ruled out.
- **Do nothing and leave the integration in place.** Rejected: the gate mutes every session by default, so the user's agents are silent unless they opt in, one session at a time, by typing into that session's terminal. That is the behaviour that started this.

## Consequences

- Any opencode session that had not been muted keeps its `disabled-<session id>` marker in `/tmp/superwhisper-agent/`. Those files are meaningless once the plugin is uninstalled, and they are cleared when the machine reboots.
- AMA no longer has any path to speak to the user through a third-party app. Until AMA's own voice mode exists, an agent that finishes is silent.
- The opencode plugin the gate used to gate is gone from the user's opencode configuration. Its own per-session enable/disable tool is gone with it.
- A future ADR will record how AMA captures the microphone, recognises speech, routes it to an agent and speaks the reply. That decision does not depend on Superwhisper.
