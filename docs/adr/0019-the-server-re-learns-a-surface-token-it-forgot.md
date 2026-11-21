# 19. The server re-learns a surface token it forgot, before it mints a new one

Date: 2026-11-20
Scope: web

## Status

Accepted

## Context

A surface token binds a pane to its AMA session. The agent inside the pane reads it from its environment and presents it when it reports, so the server can tell which session a report belongs to.

The server's map of those tokens lives in memory. It is written when a session is created, when one is restored, and when one is renamed — and nowhere else. The restore rule makes the gap: `restore-plan.js` deliberately leaves a tmux session that already exists alone, so a server restart mints no new token for the panes that survived it.

The pane does not forget. `tmux new-session -e AMA_SURFACE_TOKEN=…` puts the token in the session's environment, and tmux keeps it for as long as the session lives. So after a restart the two sides disagree: the pane holds a token the server has never heard of.

Measured against a live server, for a session created on 17 November and alive across a restart:

- the pane's own token, with a task → `422 Unmatched` — the server cannot place it;
- a registry session id, with a task → `403 Task requires a surface token` ([ADR 0016](0016-web-server-task-pass-through.md) §7).

So no live AMA-created session could report a task at all. And the Claude Code hook presents *only* a token, so its status events 422 as well — a silent loss of status that predates the task channel and that [ADR 0007](0007-what-the-server-does-not-defend-against.md) predicted in other words.

Two ways to close the gap: mint a new token for the pane, or re-learn the one the pane already holds. Minting is the wrong answer. The token reaches the agent through the environment, and `tmux set-environment` reaches only *new* processes — probed on a live session: a new window in the session saw the published value, the shell already running did not. A newly minted token would never reach the agent that is already running.

## Decision

**Re-learn before re-issue.** The server reads a token out of the pane's own tmux environment rather than minting a second one the running agent cannot know about.

The rules live in `web/surface-token-recovery.js`, which is pure — the parsing, the decisions and the memoisation are testable without tmux — and `server.js` only performs the calls.

### 1. One rule, three outcomes

`ensureTokenForSession(name)`:

- the server knows a token for the session → **use** it;
- the pane still holds one → **adopt** it;
- neither → **mint** a fresh one, publish it into the pane's tmux environment, and adopt it.

### 2. Two ways to reach the rule

A **boot sweep**: list the live sessions and adopt the token each pane still holds. It runs once at startup and again when the restore finishes, because tmux may come up after the server does — the server is a launchd agent and tmux belongs to the operator's shell.

A **lazy lookup**: a report that presents a token the server has never seen triggers the same sweep before the identity is resolved. This is the case the sweep alone cannot cover — a token minted after the last sweep is found this way, and a report that arrives after the server started but before the sweep ran is not lost.

### 3. Adoption is additive

A binding is never revoked and never re-pointed. A token tmux reports for a session the server already knows is skipped; a token the server has bound to a *different* session is skipped there too, and the existing binding survives. More than one token may map to one session.

The reason is the same fact as in the Context: `tmux set-environment` reaches only new processes, so the agent already running still holds the token the server minted. Dropping it would lock out the very session being repaired.

### 4. Minting happens on first contact

A session the operator started themselves has no token anywhere. The first report that names it — a status report is enough — mints one, publishes it into that pane's tmux environment, and adopts it. That report is answered without a task; the next one can carry one.

The minted token is never echoed to the reporter. The requester triggers the mint; the agent picks the credential up from tmux.

### 5. The token is a separation mechanism, not a secrecy boundary

A surface token says *this report comes from this session's own agent*. It does not protect against the operator's own machines: AMA has no authentication ([ADR 0007](0007-what-the-server-does-not-defend-against.md)), the trusted-source gate already trusts the whole tailnet, and a peer on the tailnet can drive the API with a plain `curl` today. A remote peer cannot read this machine's tmux environment, so it still cannot forge a token — but that is the boundary, and it is the gate, not the token.

### 6. Both are rate limited

A sweep costs a tmux call per live session and a mint costs a `set-environment`. Both are floored: at most one sweep per `ALL_MY_AGENTS_SURFACE_TOKEN_MIN_INTERVAL_MS` (10 s by default), at most one mint per session per interval, and a token the server has already swept for is never swept for again. A reporter that keeps presenting unknown tokens cannot turn this into a tmux hammer.

### 7. The adapters resolve their token at report time

`tmux set-environment` reaches only new processes, so an agent that was already running when a token was published will never see it in its environment. Both integrations therefore resolve their token when they report: the process environment first, then `tmux display-message -p -t "$TMUX_PANE" '#{session_name}'` followed by `tmux show-environment -t <session> AMA_SURFACE_TOKEN`. The environment stays the fast path; tmux is the fallback.

## Alternatives considered

**Mint a new token for a surviving pane.** Rejected: the running agent would not receive it, so the session would still be unable to report — the failure would be quieter, not fixed.

**Read the token from the pane only when a report presents an unknown one.** Rejected: the boot sweep also repairs the *status* channel for a Claude Code pane that never reports again, and a server that starts before tmux would leave every pane token-less until it was next restarted.

**Store the tokens on disk.** Rejected: the pane is already the durable copy. A second store is a second thing to keep in step with the panes, and it would put tokens on disk where ADR 0007's whole argument is about not needing to.

**Drop the session-id fallback and fail closed on an unknown token.** Rejected, for the reason ADR 0007 gave: a pane whose token cannot be placed would lose its event status permanently and fall back to screen detection. With re-learning, the fallback is now only load-bearing for a session that has no token at all.

**Require the surface token for every event, not just tasks.** Rejected for now: it changes the blast radius of every integration to fix a channel that is not the one being spoofed.

## Consequences

- A server restart no longer costs a session its ability to report. The token the agent holds keeps working.
- The Claude Code hook's status events stop 422-ing after a restart.
- A session the operator started themselves gets a token on first contact, published into its tmux environment, and can report a task from then on.
- The server reads tokens out of tmux. That is a new coupling to tmux's session environment, and it is why `tmux show-environment -t <session>` is part of the contract: the variable is the eligibility test — a pane has one only because AMA put it there.
- The minted token lives in the pane's tmux environment, visible to `tmux show-environment` and to anything running as the same user. It is not visible in the agent's own environment, so the adapters must look for it.
- A foreign session running **only** Claude Code can never trigger the mint: the hook has neither a session id nor a token, so it reports nothing at all. The session stays token-less until something else reports for it.

## Implementation Checklist

- [x] The pure rules live in `web/surface-token-recovery.js`.
- [x] `server.js` re-learns a token on a boot sweep and on a report that presents an unknown token.
- [x] A session with no token at all is given one on first contact, published into its tmux environment.
- [x] Both integrations resolve their token at report time, from the environment or from tmux.
- [x] Both paths are rate limited.

## Related

- [ADR 0007](0007-what-the-server-does-not-defend-against.md) — the session-id fallback, and what AMA does not defend against.
- [ADR 0016](0016-web-server-task-pass-through.md) — the task channel the recovered token feeds.
- [ADR 0015](0015-agent-task-state-local-first.md) — the macOS side of the task channel.
- [ADR 0003](0003-trusted-source-gate.md) — the trusted-source gate, which is where the real boundary is.
