# 5 — A slow shell is not a failed launch, and a failed launch leaves nothing behind

Part of: .scratch/task-factory-integration/spec.md
Status: done — branch `issue/05-a-slow-shell-is-not-a-failed-launch`
Labels: bug

## What to build

Starting a session must survive a shell that takes its time, and must not leave a session behind
when it does not.

The live evidence: creating a session through the create route took **5.048 seconds** against a
five-second readiness window, and on the task that triggered this ticket the same call failed
with `500 {"error":"the pane's shell never became ready"}` — leaving a tmux session that was
registered as a plain shell, with no group, no state and no launch command. The shell on this
machine draws its prompt in about a second interactively, but in a freshly created pane the
readiness check polls `capture-pane` every 25 ms while each poll costs a process spawn of roughly
a quarter of a second — so the check is slow to notice a prompt that has already appeared, and
sits right on its own deadline.

So:

- **Wait longer, and wait for the right thing.** The readiness check gives the pane a much longer
  window (tens of seconds, not five), polls at a saner interval, and — crucially — looks for a
  **shell prompt** at the end of the pane's content rather than for *any* content at all. A pane
  that has printed a login banner but not yet drawn its prompt is **not** ready: typing into it
  echoes the command twice and can lose characters, which is exactly what the existing comment
  warns about.
- **Leave nothing behind when it fails.** If the pane never becomes ready, the half-created
  session is destroyed before the error is returned. No orphaned tmux session, no registry entry, no
  half-session in the sidebar that looks alive but never runs anything.
- The refusal stays what it is: a 500 with the same message, so nothing downstream changes shape.

## Acceptance criteria

- [ ] A pane whose prompt appears late is waited for, and the launch succeeds
- [ ] A pane showing content that is not a prompt (a banner, a half-drawn line) is not ready
- [ ] A pane that never becomes ready leaves no tmux session and no registry entry
- [ ] The failure still answers 500 with the same message
- [ ] The readiness window is longer than it was, and the poll interval is not tighter than the cost of a poll
- [ ] Nothing types into a pane that has not drawn its prompt

## Blocked by

None
