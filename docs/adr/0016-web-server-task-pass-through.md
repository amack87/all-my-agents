# 16. The web server passes task state through, no aggregation

Date: 2026-11-17
Scope: web

## Status

Accepted

## Context

ADR-0015 chose **local-first task state**: the macOS app holds the task, the server does not
persist it. That leaves one question — what is the server's part?

The server already owns the path an agent's task travels:

1. the agent POSTs to `POST /api/events` (`web/server.js`), the only write channel a session
   has into the server;
2. the server keeps per-session state in memory (`eventStates`, `taskStates`);
3. the server publishes a snapshot of every session it knows about — locally discovered tmux
   panes and the sessions of every configured mesh peer — over `GET /api/sessions`,
   `GET /api/mesh/sessions` and the `/ws/status` feed.

So the server is already the mesh aggregator, and the task either rides that pipeline or it
does not exist. The question is not *whether* the server touches the task, but *how much* it
does to it.

The tempting move is to make the server "helpful": trim phrases, normalise casing, merge
"Fixing bug" with "Fixing bug #123", or infer a task from the pane when none was reported.
All of that is the server deciding what an agent is doing, on the strength of strings the
agent wrote.

## Decision

The server's job is **pass-through with a bound**. It carries the task, unchanged, from the
event to the snapshot — and it refuses to be more than 200 characters.

### 1. The event channel accepts an optional task

`POST /api/events` accepts `task` alongside `event`, `sessionId`, `surfaceToken` and
`message`. A `task` that is present, non-null and not a string is a **400 Malformed event
payload** — the same rule the other fields follow.

### 2. Three rules, and only three (`web/task.js`)

`web/task.js` is a pure module; `canonicalTask` and `applyTaskUpdate` have no I/O and are
unit-tested against the shared fixture.

| Input | Effect | Result |
|---|---|---|
| field absent | **keep** | the stored task is left alone |
| `null`, `""`, whitespace | **clear** | the stored task becomes `null` |
| a non-empty string | **set** | trimmed, and capped at 200 characters |

Capping truncates to 197 characters and appends `...` — 200 in total. A field that is absent
must not erase the task: an agent posting a status-only event says nothing about the task,
and treating silence as "no task" would make the task flicker off on every status ping.

### 3. Storage is in-memory, keyed by session and pane

`taskStates` in `web/server.js` holds `session name → task` and `pane id → task`, the same
double key `eventStates` uses, so a session is found by either name the caller knows.

### 4. The relay is unchanged

The task rides the existing snapshot pipeline with no transformation:

- the local session builder adds `task` to each session it discovers;
- `web/mesh.js` copies `task` verbatim from a peer's `GET /api/sessions`;
- `web/status-feed.js` includes the task in the snapshot signature, so a **task-only change
  is pushed** — otherwise the feed would see an identical signature, decide nothing had
  changed, and the macOS app would never learn about it.

### 5. The server does not escape — the renderer does

The server carries the task as bytes. The renderer owns escaping: `web/public/session-task.js`
builds the tile's task span through `esc()`, the same helper the rest of the tile uses. A
task is free text written by an agent (and therefore prompt-influenceable) and may arrive
from a peer; it must never reach `innerHTML` unescaped.

### 6. The contract declares it

`contract/api-contract.json` (version 6) declares `task` in `session`, `meshSession` and
`eventAck` — a string or null. The shape guard is strict, so a field that is not declared
is a violation; publishing the field *is* the declaration.

`contract/task-update.json` holds the canonical cases — the three rules above, plus hostile
markup (`<script>`, an attribute-breaking quote, an ampersand) asserted **verbatim**, so no
layer may quietly "clean" a task. Both suites read it: `web/test/task-contract.test.js`
(canonicalisation) and `Tests/AllMyAgentsTests/TaskContractTests.swift` (the wire form).

### 7. Only the surface token may write a task

A task is the agent's own voice — it says what that agent is doing, and it lands in the
sidebar the user supervises. The session's **surface token** is the only credential that
authorises it: a task posted without a token, or with another session's token, is a
**403 Task requires a surface token**.

A **registry session id** is not a credential. It is readable from the unauthenticated
`GET /api/registry`, so anything that can reach the server can read it. It still authorises
*status* events on the pre-existing channel, and it must not authorise a task: a spoofed task
is a lie in the user's face, in the one place the user looks to see what their agents are up
to.

Status events keep the looser rule. Tightening that channel is a decision about
`/api/events` as a whole, not this ADR's business.

Neither agent integration reports a task yet — `web/integrations/claude/ama-status-hook.js`
and `web/integrations/opencode/ama-status.js` post status events — but both already send the
surface token when they have one, so extending them to report a task brings the credential the
channel requires. An agent that has no token may still report status; its tasks are refused.

The token the rule names is one the server issued. A server restart forgets the tokens it
minted ([ADR 0019](0019-the-server-re-learns-a-surface-token-it-forgot.md)), so the server
re-learns the token a pane still holds rather than minting a second one, and mints one for a
session that has none when that session is first contacted. Either way the token in the
author's hand is the one the server knows for that session.

## Alternatives considered

#### A. Server infers task state from screen content

**Rejected**: the server already screen-scrapes for status, and that heuristic is imperfect
enough. Reading pane content to invent a task description would be inaccurate, expensive, and
would quietly expose agent output to a second consumer.

#### B. Server normalises task strings

**Rejected**: "Fixing bug" and "Bug fix: #123" are the agent's words; the server has no
business rewriting them into a house style. Trimming whitespace and capping a length are not
normalisation of meaning — they are bounds on what one caller can put in one field.

#### C. Leave the cap to the agent

**Rejected**: the agent is the untrusted party and the server is the trust boundary. Every
other input into this server is validated server-side; a task would be the one field the
caller sizes. It is also an amplification: one POST is relayed into every `/ws/status`
subscriber and every `/api/mesh/sessions` reader, so an unbounded string is cheap to send
and expensive to fan out. The 100 kb body cap is far larger than a task line — it bounds the
request, not the field.

#### E. Require the surface token for the whole event channel

**Rejected for now**: a task is the agent's own voice and belongs in the sidebar the user
supervises, so it gets the token. A status is a coarser signal the sidebar already tolerates
from any source that can reach the server. Tightening the whole channel is a bigger change
with its own blast radius — it would touch every existing agent integration — and it is not
what this ADR is about.

#### D. Server persists task state for restart recovery

**Rejected for now**: ADR-0015 puts the state in the app. Persistence is the obvious later
step if task history is wanted, and it belongs with the app, not the server.

## Consequences

#### Positive

- **Small, honest change**: one optional field on an existing channel.
- **Peers work**: the task crosses the mesh unchanged, because the peer's server relays it
  the same way.
- **The task is a push, not a poll**: a task-only change reaches every watching device.

#### Negative

- **No history, no persistence**: the task lives in memory on the server and in memory in
  the app. A server restart drops it until the agent reports again.
- **One task per session**: two agents sharing a pane share one task slot.
- **The bound is visible**: a task longer than 200 characters is truncated by the server, and
  the agent — not the user — is the one who has to notice.

### Known limits

- The **status** channel still accepts a registry session id as an alternative to a surface
  token. That is pre-existing and unchanged here, so anything that can reach the server can
  report a status for a session it does not own. Tightening it belongs to a decision about
  `/api/events` as a whole.

- A **foreign session running only Claude Code** can never trigger the mint: the hook has
  neither a session id nor a token, so it reports nothing at all, and the session stays
  token-less until something else reports for it
  ([ADR 0019](0019-the-server-re-learns-a-surface-token-it-forgot.md)).

## Implementation Checklist

- [x] `POST /api/events` accepts an optional `task` and rejects a non-string one
      (`web/server.js`)
- [x] The three rules live in a pure module (`web/task.js`) and are unit-tested
- [x] The task is stored per session and per pane, in memory (`web/server.js`)
- [x] The local session list carries the task (`web/server.js`)
- [x] `GET /api/mesh/sessions` and the `/ws/status` snapshot carry the task
      (`web/server.js`, `web/mesh.js`)
- [x] The snapshot signature includes the task, so a task-only change is pushed
      (`web/status-feed.js`)
- [x] The renderer escapes the task (`web/public/session-task.js`)
- [x] A task may only be written by the holder of the session's surface token
      (`web/server.js`)
- [x] The contract declares `task` (`contract/api-contract.json`, version 6)
- [x] The shared fixture carries hostile inputs and is read by both suites
      (`contract/task-update.json`)

## Related

- ADR: `docs/adr/0015-agent-task-state-local-first.md` (the app's side of the channel)
- ADR: `docs/adr/0005-origin-allowlist.md` (the other place the server is told what to
  believe)
