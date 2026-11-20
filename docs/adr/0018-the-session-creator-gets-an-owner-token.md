# 18. The session creator gets an owner token

Date: 2026-11-20
Scope: system

## Status

Accepted

## Context

ADR 0017 gave the server three session fields it owns — `group`, `dir` and `state` — and said the
task state is written by "the workflow's owner, through the server's API". That phrasing hid a
problem: Task Factory is a separate program, and nothing in the API distinguishes it from any
other caller.

The server already has a per-session secret, the **surface token**, but it points the wrong way.
It is minted at creation and passed into the pane's environment, where an agent adapter picks it
up and uses it to prove itself on `POST /api/events`. It belongs to the agent — it is what an
agent proves it is — and it is deliberately not returned to the creator. Handing the creator the
same secret the pane holds would collapse the two roles into one credential: anything running
inside the session could then also write the session's workflow state, which is exactly what
ADR 0017 forbids.

Meanwhile the state-write route cannot simply be open. The server accepts connections from
anywhere on the trusted network (ADR 0003), and that gate answers "where did the request come
from", not "who sent it". The agent's own shell sits on loopback alongside Task Factory. A route
that lets anyone who can reach the server declare a task `done` is not server-owned state at
all — it is a public write with extra steps.

So the state write needs its own authoriser, issued to the creator and only to the creator.

## Decision

Session creation mints a second per-session secret: the **owner token**.

- `POST /api/sessions` returns `{ok, name, command, ownerToken}`. The token is returned **once**,
  in the create response; it appears in no session shape, in no log, and in no published
  contract shape. (Like the surface token, error text that could embed it is redacted — the same
  `redactTokens` pass covers both.)
- It is opaque — the same generator mints it as mints surface tokens — and it is scoped: it may
  write **that session's** state and nothing else. `POST /api/sessions/{name}/state` requires it;
  a wrong or missing token is answered `401`.
- The agent cannot claim a state: `POST /api/events` refuses the `state` field outright, the
  same way it refuses `group` and `dir`, so a surface token is not an owner credential no matter
  what it is used for.
- The token travels with the session through a rename and is dropped when the session is
  deleted. It lives in memory only, like the surface token: a server restart ends every owner
  token, and the state the registry carries is then read-only until the session is claimed again
  by a fresh creation.

All My Agents stores and publishes the state; it does not interpret it. The vocabulary —
`grilling`, `spec_ready`, `issues_ready`, `awaiting_approval`, `executing`, `done`, `failed`,
`parked` — is Task Factory's, and a session's state is an opaque string here, bounded the way the
other published strings are (length, single line) so no surface is handed something it cannot
store or render.

## Alternatives considered

#### A. Trust the request's origin

**Rejected**: on loopback, origin is not identity. Task Factory, a stray script, and the agent's
own shell all arrive from the same place. ADR 0003's gate is about *where* a connection comes
from; it was never meant to answer *who* is calling. Origin-based authorisation would let
anything local drive every session's state, and the agent — the one writer ADR 0017 most needs
to exclude — is local by construction.

#### B. Let the agent write its own state

**Rejected** for the same reason ADR 0017 rejected carrying workflow state in the `task` field:
the agent's words and the workflow's position are different facts. An agent that hangs would
still report idle-with-a-state, and an agent that lies (or is prompted badly) could declare its
own task `done`. The state is the workflow's memory, not the agent's self-report.

#### C. Hand the creator the surface token and call it the owner credential

**Rejected**: the surface token's job is to live in the pane's environment. A creator that
"holds" it holds a secret that is by design shared with everything running in the pane. Two
roles, one secret, no boundary — the route may as well not check.

#### D. Per-caller API keys

**Rejected for now**: a single-user server does not need an account system, and an account key
would authorise writes to *every* session's state, not one. The per-session scope is the
boundary that matters; a global key would be a coarser version of the same idea with more
machinery to lose.

## Consequences

- AMA's published contract changes: **version 10** (the session shape gains `state`, the create
  response gains `ownerToken`, and a new `sessionState` route/shape is published). The shared
  fixture gains the state case, asserted in both suites.
- Task Factory must store the owner token with the task it created; a lost token means the
  session's state can no longer be written by anyone, and the recovery is creating the session
  again. That is acceptable — the token is one field in Task Factory's own task record.
- The token does not survive a server restart. The state itself does (the registry carries it),
  but after a restart it is read-only until the session is recreated. Workflows that outlive a
  restart will notice; if that ever matters, a persisted-token scheme is a follow-up ADR.
- Two per-session secrets now exist with different lives: the surface token belongs to the pane
  and is passed into its environment; the owner token belongs to the creator and is handed to
  the caller. Nothing shares them, and neither appears in a published shape.

## Implementation Checklist

- [] `POST /api/sessions` accepts an optional initial `state` and returns `ownerToken`
- [] `POST /api/sessions/{name}/state` writes the state, only with the right owner token;
      `state: null` clears it
- [] `POST /api/events` refuses `state` (with `group` and `dir`)
- [] the owner token is redacted from error text, travels with renames, and is dropped with the
      session
- [] `session`, `meshSession` and the `/ws/status` snapshot publish `state`; the create response
      publishes no token but its own
- [] restore carries the state, the same way it carries the group and the directory
- [] the contract is at version 10, with the state case in the shared fixture asserted by both
      suites

## Related

- ADR: `docs/adr/0017-sessions-declare-group-state-and-working-directory.md` (the server-owned
  fields this token authorises writing)
- ADR: `docs/adr/0003-trusted-source-gate.md` (what the network gate does and does not answer)
- ADR: `docs/adr/0015-agent-task-state-local-first.md` and
  `docs/adr/0016-web-server-task-pass-through.md` (the agent's own task field, a different fact)
