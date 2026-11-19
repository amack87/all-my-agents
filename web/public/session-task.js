// Rendering a task into the session tile.
//
// A task is free text an agent reported about itself, so it can carry
// anything — including markup. The tile is built as an HTML string, so a task
// has to be escaped exactly like every other value that reaches it (see
// escape.js, and ADR 0005 for why that matters).
//
// Pure and DOM-free so it can be unit tested without a browser.

import { esc } from "./escape.js";

/**
 * The markup for a session's task, or nothing when it has no task.
 */
export function taskHtml(task) {
  if (task === null || task === undefined || task === "") return "";
  return `<span class="session-task">${esc(task)}</span>`;
}
