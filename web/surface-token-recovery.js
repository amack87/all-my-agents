// Pure rules for recovering a surface token the server has forgotten.
//
// The server keeps its surface tokens in memory. A pane keeps its own token in
// its tmux environment. When the server restarts it forgets every token it
// minted, but the panes do not forget theirs — so a live session can no
// longer be identified and can no longer report a task.
//
// The fix is to re-learn the token the server already gave that pane, rather
// than to mint a new one: `tmux show-environment -t <session>` still prints
// `AMA_SURFACE_TOKEN`. A running agent holds the old token, so re-issuing
// would lock the session out of its own channel.
//
// Everything in this module is pure: the tmux calls live in server.js, and the
// rules here are driven by injected values in the tests.

export const SURFACE_TOKEN_ENV = "AMA_SURFACE_TOKEN";

// Read the token out of the output of `tmux show-environment`.
//
// The output is one `NAME=value` line per variable, or `-NAME` for a variable
// that is explicitly unset. Only an exact `AMA_SURFACE_TOKEN=` match counts,
// so a variable that merely starts with the same letters cannot be mistaken
// for the token.
export function parseSurfaceToken(envOutput) {
  if (typeof envOutput !== "string") return null;
  const prefix = `${SURFACE_TOKEN_ENV}=`;
  for (const line of envOutput.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith(prefix)) continue;
    const value = trimmed.slice(prefix.length);
    return value.length ? value : null;
  }
  return null;
}

// Decide which token→session bindings to add, given the tokens read from tmux
// for a set of sessions and the bindings the server already knows.
//
// Additive only: a binding is never revoked and never re-pointed at another
// session. A token the server already knows for that same session is skipped;
// a token the server knows for a *different* session is also skipped, because
// re-pointing it would take that session's credential away. Two sessions
// cannot share a token — every token is fresh random bytes minted for one
// session — so that guard protects a case that cannot arise rather than
// costing anything.
export function planAdoptions(entries, knownTokens = new Map()) {
  const bindings = [];
  const adopted = [];
  const skipped = [];
  const seen = new Set();

  for (const entry of entries) {
    const name = entry?.name;
    const token = entry?.token;
    if (!name || !token) {
      skipped.push({ name, token, reason: "no-token" });
      continue;
    }
    const key = `${name}\u0000${token}`;
    if (seen.has(key)) {
      skipped.push({ name, token, reason: "duplicate" });
      continue;
    }
    seen.add(key);
    const bound = knownTokens.get(token);
    if (bound === name) {
      skipped.push({ name, token, reason: "already-known" });
      continue;
    }
    if (bound) {
      skipped.push({ name, token, reason: "bound-elsewhere" });
      continue;
    }
    bindings.push({ token, name });
    adopted.push({ token, name });
  }

  return { bindings, adopted, skipped };
}

// What to do about one session's token.
//
// use   — the server already knows a token for this session
// adopt — the server knows none, but the pane still holds one: re-learn it
// mint  — the server knows none and the pane holds none: issue a new one
export function recoveryAction({ name, token, knownToken } = {}) {
  if (knownToken) return { action: "use", token: knownToken };
  if (token) return { action: "adopt", token };
  return { action: "mint", token: null };
}

// Whether an unknown token justifies sweeping the live sessions for their
// tokens.
//
// Memoised per token rather than per unit of time: a token minted after the
// last sweep is still found, and a reporter that repeats a token it does not
// own cannot turn the sweep into a tmux hammer.
export function shouldSweep({ token, sweptTokens } = {}) {
  if (!token || !sweptTokens) return false;
  return !sweptTokens.has(token);
}
