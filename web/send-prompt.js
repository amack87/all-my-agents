// Deliver a prompt to a session as the agent's own typed input — the pure
// parts of POST /api/sessions/:name/send. The route resolves the session's
// pane id with tmux and then runs the two calls below; everything that can be
// decided without tmux (is the body a prompt, what argv delivers it) lives
// here so it is testable without a tmux server.
//
// The argv comes from surface-token.js — the same helpers that type the
// launch command into a fresh pane — so a prompt can never drift onto a
// different sending scheme than a launch: the text is typed literally
// (`-l`, so it is never read as a list of key names; `--`, so a prompt that
// begins with a dash is not read as options) and Enter is a separate call
// (because `-l` would send the word "Enter" as literal text).

import { buildLaunchInputArgs, buildLaunchSubmitArgs } from "./surface-token.js";

/**
 * Validate the send body: `{ text: "<the prompt>" }`, where text is a
 * non-empty string. Returns `{ ok: true, text }` or `{ ok: false, error }`.
 * The text is not trimmed or altered — it is sent byte for byte.
 */
export function validateSendBody(body) {
  const text = body?.text;
  if (typeof text !== "string" || text.length === 0) {
    return { ok: false, error: "Body must be { text: <non-empty string> }" };
  }
  return { ok: true, text };
}

/**
 * The argv of the two send-keys calls that deliver a prompt, in order: the
 * text literally, then Enter.
 */
export function sendPromptCalls(paneId, text) {
  return [buildLaunchInputArgs(paneId, text), buildLaunchSubmitArgs(paneId)];
}
