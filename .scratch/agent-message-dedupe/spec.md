# PRD: The message store does not file the same message twice

Status: ready-for-agent
Tracker: this repository, `.scratch/agent-message-dedupe/`

## Problem Statement

An agent's message appears twice in the panel, and twice in the transcript of whatever is reading it.

The cause is on the agent side. Claude Code fires its `Stop` hook twice for one turn — once after the
assistant's text, once after a tool-use turn — and each firing carries the same
`last_assistant_message`. The server files both, because as far as it can tell they are two
messages.

Every consumer pays for it: the panel shows the same line twice, and a transcript built from the
message route records two turns for one piece of speech. A reader cannot tell which of the two is
real, so the conversation looks like the agent repeated itself.

## Solution

The message store recognises a repeat and files it once.

The repeat is easy to recognise and easy to mistake. The same text arriving twice in quick
succession from the same agent is one message; the same text arriving again minutes later is the
agent saying it again, and must still be filed.

## User Stories

1. As James, I want an agent's message to appear once in the panel, so that the conversation reads
   as what the agent said.
2. As James, I want a transcript built from the messages to hold one turn for one thing the agent
   said, so that the record matches the panel.
3. As James, I want the agent to be able to genuinely repeat itself later and have that shown, so
   that the fix does not hide real repetition.
4. As James, I want my own replies never to be dropped, so that answering the agent twice by
   mistake still sends both.

## Implementation Decisions

- **The store recognises the repeat, not the sender.** The comparison happens where the message is
  filed, so every consumer benefits and no client has to know about it.
- **Only agent-origin messages are concerned.** A message from the panel is never a duplicate of an
  agent message and is never dropped.
- **The window is short and the comparison is exact.** The same text, from the same origin, within a
  short window of the previous message is the same message. A repeat outside that window is a new
  message and is filed.
- **Nothing about the published contract changes.** The shape of a message is the same; there is
  simply one of it where there were two.

## Testing Decisions

A good test asserts what a person sees: the same message filed twice in quick succession appears
once; the same message filed again later appears again; a panel reply is never dropped.

The seam is the message store, exercised directly with a controlled clock — the window is the
behaviour, and a test that sleeps to prove it is a slow test.

## Out of Scope

- Changing how Claude Code fires its hooks.
- Any change to the published contract or to either client.
- De-duplicating across sessions, or de-duplicating a panel reply against an agent message.

## Further Notes

This was found by running Task Factory end to end: the agent's first question reached the panel
twice. The fix belongs here, in the shared surface, because every agent integration will hit it.
