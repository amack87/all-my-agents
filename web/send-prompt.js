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
 * Validate the send body: `{ text: "<the prompt>", origin?: "panel" }`, where
 * text is a non-empty string. Returns `{ ok: true, text, origin }` or
 * `{ ok: false, error }`. The text is not trimmed or altered — it is sent
 * byte for byte.
 *
 * `origin` is where the message came from, filed with it by the route. The
 * panel declares "panel"; the only value accepted, because a tag that
 * accepts any string means nothing. An absent origin is null — text the
 * server delivered for a caller that did not say where it came from. Text
 * typed into a terminal never goes through this route, so it is never
 * tagged at all.
 */
export function validateSendBody(body) {
  const text = body?.text;
  if (typeof text !== "string" || text.length === 0) {
    return { ok: false, error: "Body must be { text: <non-empty string> }" };
  }
  const origin = body?.origin;
  if (origin !== undefined) {
    if (origin !== "panel") {
      return { ok: false, error: "origin must be \"panel\" when present" };
    }
    return { ok: true, text, origin };
  }
  return { ok: true, text, origin: null };
}

/**
 * The argv of the two send-keys calls that deliver a prompt, in order: the
 * text literally, then Enter.
 */
export function sendPromptCalls(paneId, text) {
  return [buildLaunchInputArgs(paneId, text), buildLaunchSubmitArgs(paneId)];
}
