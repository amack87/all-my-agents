// "Needs you" — the view of who is waiting on James.
//
// It lists exactly the sessions in a group whose status is needsInput,
// oldest wait first. It is a view, not a coordinator: nothing changes
// because of it, and a session that belongs to no group is not on it.
//
// The wait is read off the session's own last activity: for a session
// waiting on input, the last thing it did was ask — so `lastActivity`
// (tmux's session activity, epoch ms) is when the wait began, and
// ascending lastActivity is oldest wait first. A session that never
// produced activity reads as 0 and sorts first; there is nothing older
// than a wait whose start is unknown.

// Which status says a session is waiting on input.
export const NEEDS_INPUT_STATUS = "needsInput";

/** The sessions waiting on James, oldest wait first. */
export function needsYou(sessions) {
  return sessions
    .filter((s) => !!s.group && s.status === NEEDS_INPUT_STATUS)
    .sort((a, b) => (a.lastActivity || 0) - (b.lastActivity || 0));
}
