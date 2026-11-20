# 1 — The message store does not file the same message twice

Part of: .scratch/agent-message-dedupe/spec.md
Status: done — branch `issue/01-the-message-store-does-not-file-the-same-message-twice`
Labels: bug

## What to build

The message store files an agent's message once, even when the agent's hook delivers it twice.

Claude Code fires its `Stop` hook twice for one turn — once after the assistant's text, once after a
tool-use turn — and each firing carries the same `last_assistant_message`. The server files both,
because as far as it can tell they are two messages. The panel shows the same line twice, and a
transcript built from the message route records two turns for one thing the agent said.

- The store recognises the repeat where the message is filed, so every consumer benefits and no
  client has to know about it.
- Only agent-origin messages are concerned. A message from the panel is never dropped, and is never
  treated as a repeat of an agent message.
- The window is short and the comparison is exact: the same text, from the same origin, within the
  window of the session's previous message is the same message. A repeat outside the window is the
  agent saying it again, and is filed.
- The window is a value, not a constant buried in the comparison, and it is documented where it
  lives.
- Nothing about the published contract changes: the shape of a message is the same, there is simply
  one of it where there were two. No contract version bump, no fixture case.

## Acceptance criteria

- [ ] The same agent message filed twice in quick succession is stored once
- [ ] The same agent message filed again outside the window is stored again
- [ ] A panel reply is always stored, never treated as a repeat
- [ ] The panel shows one message where the agent's hook delivered two
- [ ] The stored message keeps its identifier and its timestamp from the first filing
- [ ] Nothing in the published contract changes

## Blocked by

None - can start immediately
