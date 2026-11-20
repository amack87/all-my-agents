# 04 — The server carries a task's state

Part of: .scratch/task-factory-integration/spec.md
Status: ready-for-agent
Labels: enhancement

## What to build

Ticket 01 gave the server ownership of a session's group and working directory. The third
server-owned field is still missing: the session's **state** — where the task stands in its own
pipeline (`grilling`, `spec_ready`, `issues_ready`, `awaiting_approval`, `executing`, `done`,
`failed`, `parked`). Task Factory declares it; the server stores it, publishes it and refuses to
let an agent write it.

Task Factory is a separate program, so it needs a way in. The surface token belongs to the agent
— it is what an agent proves it is — and it is deliberately not handed to the creator, so it
cannot be the answer. The create route therefore returns an **owner token**: an opaque
per-session secret, given to whoever created the session, able to write that session's state and
nothing else. It is returned once, in the create response, and appears in no published session
shape — the same treatment the surface token gets, except that this one is handed to the caller
rather than into the pane's environment.

All My Agents stores the state and publishes it. It does not interpret it: the vocabulary is
Task Factory's, and a session's state is an opaque string to this repository.

- The session shape gains a nullable `state`, published wherever a session is published.
- Session creation accepts an optional initial `state`, and returns an `ownerToken`.
- A new route writes the state of a session, and only with the right owner token.
- `POST /api/events` still refuses `state` — the agent can never claim a state.
- Restore carries the state, like the group and the directory.
- The published contract moves on, and the new behaviour gets a case in the shared fixture that
  both suites assert.

Record the owner-token decision as an ADR: it is a security boundary, and the alternatives —
trusting the request's origin, or letting the agent write its own state — are worth remembering.

## Acceptance criteria

- [ ] A created session publishes `state` (null when none was given) everywhere a session is published
- [ ] The create response carries an owner token, and it appears in no session shape, log or published contract shape
- [ ] The owner token writes the state; a wrong or missing token is rejected
- [ ] The agent's event route refuses `state`, and so refuses the other server-owned fields
- [ ] A restored session comes back with its state
- [ ] The contract version moves, and the shared fixture has a case asserted by both suites
- [ ] An ADR records the owner-token decision and the alternatives it beat

## Blocked by

01 — the server owns a session's group and directory (merged)
