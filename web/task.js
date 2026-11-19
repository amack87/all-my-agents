// The task channel: what an agent is doing right now.
//
// A task is free text an agent reports about itself. It arrives from the
// agent — the untrusted party — travels through the server, and is rendered
// by the web app and the macOS app.
//
// The server carries it; it does not understand it. It does not reword,
// dedupe or classify it, and it does not escape it: escaping here would put
// "&lt;" in the sidebar instead of a task. The renderer escapes (see
// public/session-task.js).
//
// What the server does do is bound it. One POST is amplified into every
// status-feed subscriber and every mesh reader, and the body cap (100 kb) is
// far larger than a task line needs to be — so a task is trimmed and capped
// here, once, for everybody.
//
// Pure and DOM-free so it can be unit tested.

export const TASK_MAX_LENGTH = 200;

/**
 * The canonical form of a task: trimmed, bounded, and null when there is no
 * task. A value that is not a string is not a task.
 */
export function canonicalTask(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.length <= TASK_MAX_LENGTH) return trimmed;
  return `${trimmed.slice(0, TASK_MAX_LENGTH - 3)}...`;
}

/**
 * Apply a task update to the task a session currently has.
 *
 * An update that carries no task at all keeps the current one: an agent that
 * reports its status but not its task must not erase the task it reported a
 * minute ago. An explicit null — or an empty task — clears it.
 *
 * `effect` says what happened: "set", "clear" or "keep".
 */
export function applyTaskUpdate(value, current = null) {
  if (value === undefined) return { task: current, effect: "keep" };
  const task = canonicalTask(value);
  if (task === null) return { task: null, effect: "clear" };
  return { task, effect: "set" };
}
