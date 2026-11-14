# 13. AMA publishes an API for the voice bridge; the voice lane is not AMA's

Date: 2026-11-13
Scope: system

## Status

Accepted

## Context

The user runs a separate voice bridge application (`~/Repos/voice-bridge`, not part of this repository). It owns the microphone, the speech-to-text and the speech-out. It already integrates with AMA: it reads AMA's session list, adds the sessions to its own registry so they can be addressed by name, types into the agents' panes, watches for the turn to end, and speaks the answer back.

That integration was written against an assumption about AMA's API rather than against AMA's API. The assumption was that a session's status is `idle` or `busy`. AMA's server has never said `busy` — it says `working` — so the bridge's watcher waited for an edge that could not arrive, and every handoff to an AMA agent sat out its full sixty-second grace period before admitting the turn was over. The reply was still correct, because it was recovered by diffing the pane. The answer was always a minute late.

Three more consequences of the same assumption — that the API was known rather than published:

- The bridge cannot write to a session on another machine. It types into local panes with `tmux send-keys` and refuses peer sessions outright, because "a session the phone could read but never reach would be a trap".
- The bridge recovers an agent's reply by diffing two captures of a terminal, which is a screen-scraping problem wearing a different hat.
- The bridge polls AMA every five seconds for session status, and each poll costs the server a `capture-pane` and an agent detection per pane.

ADR 0012 retired Superwhisper from AMA and left the question of AMA's own voice mode open. The user's answer to that question was that AMA should not have one: the voice bridge is a separate application, and AMA is the thing it talks to.

## Decision

AMA grows no voice interface. It grows an API that a voice client can rely on, and it publishes that API as a machine-readable contract.

- **AMA publishes its contract.** `GET /api/contract` returns a document declaring the status vocabulary, the routes a client may call, and the shape of what those routes return. The same document lives as a fixture under `contract/`, so this repository's own test suites can assert the implementation against it. The contract is a versioned public surface: changing it breaks clients.
- **Clients read the contract at runtime rather than hard-coding it.** A client fetches the contract at startup and drives its own behaviour from it, keeping a vendored copy as the fallback when the server cannot be reached. A client that hard-codes AMA's vocabulary can drift from AMA silently; a client that reads it cannot.
- **Agents report their own output.** The Claude Code hook and the opencode adapter carry the assistant's message text on `POST /api/events`, alongside the status they already report. AMA stores each message against the session the surface token identifies, so "whose message is this?" is already answered.
- **AMA gains a send route and a message route.** `POST /api/sessions/:name/send` types into a pane, with the existing peer-proxy shape for a session on another machine, so any session AMA can show can also be prompted. `GET /api/sessions/:name/message` returns an agent's messages, addressable by a cursor, so a caller can ask for what an agent said since a given point rather than for whatever it last said.
- **Clients subscribe instead of polling.** The status feed AMA already serves over a WebSocket gives a client the mesh-wide session list as it changes, which is both cheaper than polling and wider than a local-only poll.

## Alternatives considered

- **AMA grows its own voice mode — microphone, speech recognition, speech out.** Rejected: the user already has a voice bridge, and said so. Two applications listening for the same speech would wake the same agents twice and answer twice.
- **Keep the client hard-coding AMA's shapes, and add a test that fails when they drift.** Rejected as the only defence: the drift test is only run when someone runs it against a live server, and the eight months of `"busy"` are the evidence that nobody does. A contract read at runtime cannot be ignored.
- **AMA reads each agent's transcript to learn what it said.** Rejected: it couples AMA to every agent's private storage format and its versioning, for a piece of information the agents can simply report. The agents that can report already have a working path to AMA, carrying the surface token that solves identity.
- **The reply keeps coming from diffing the pane.** Rejected: it is the fragility the client is trying to escape, and it costs the server a capture per poll to keep working.
- **Put the contract in a shared package both repositories depend on.** Rejected for now: two applications on one machine, one of which is not even published, do not need a registry to share a JSON document.

## Consequences

- AMA's event payload grows an optional message field. The existing adapters keep working unchanged; the ones that carry messages are the ones that can.
- An agent with no adapter — codex, cursor, aider — reports no messages, so a client asking for one falls back to the pane capture it was trying to avoid. The fallback is a gap with a deadline, not a design.
- The voice bridge becomes a second client of AMA's API. It is a separate repository with no issue tracker, so its half of the work is recorded as a migration note on the AMA issue rather than as tickets of its own.
- Any change to the contract is a change to a public surface. It needs a version bump, and the client's vendored copy needs updating with it.
- AMA's server has to store agent messages, and keep them for as long as a client might ask for one.
