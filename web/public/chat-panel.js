// The chat panel's pure parts: what a message row says about itself, and how
// the panel's list grows. The DOM wiring lives in panel.js; this module is
// testable without a browser.
//
// Vocabulary (CONTEXT.md): a message filed against a session is an agent
// message when the agent produced it, and a panel reply when James typed it
// into the panel. The origin (message-origin.js) decides which is which; the
// label only reads it.

import { isPanelMessage } from "./message-origin.js";

/** The row label for a message: who is speaking. */
export function messageLabel(message, sessionName) {
  return isPanelMessage(message) ? "You" : sessionName;
}

/**
 * Grow the panel's list by the page the server answered with. Messages arrive
 * oldest first with increasing ids; an id already on the list is skipped, so
 * a poll that overlaps the previous one never draws a message twice. Returns
 * a new list — the input is never mutated.
 */
export function appendMessages(list, page) {
  const highest = list.length > 0 ? list[list.length - 1].id : 0;
  const fresh = (page ?? []).filter((m) => m.id > highest);
  return fresh.length > 0 ? [...list, ...fresh] : list;
}
