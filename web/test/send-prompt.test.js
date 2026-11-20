// The send route's pure parts: body validation and the send-keys argv.
// tmux is not involved here; the live route is exercised by the contract suite
// (web/test/api-contract.test.js) and the shape guard on real responses.

import { test } from "node:test";
import assert from "node:assert/strict";

import { validateSendBody, sendPromptCalls } from "../send-prompt.js";

test("validateSendBody accepts a plain prompt", () => {
  assert.deepEqual(validateSendBody({ text: "fix the flaky test" }), {
    ok: true,
    text: "fix the flaky test",
    origin: null,
  });
});

// The origin travels with the body, and the route files it with the message
// it delivers. "panel" is the only value accepted: the origin tag exists so a
// consumer can trust that a panel reply came from the panel, and a tag that
// accepts any string means nothing. Text typed into a terminal never goes
// through this route, so it is never tagged at all.
test("validateSendBody accepts the panel origin and nothing else", () => {
  assert.deepEqual(validateSendBody({ text: "yes, approved", origin: "panel" }), {
    ok: true,
    text: "yes, approved",
    origin: "panel",
  });
  for (const body of [
    { text: "hi", origin: "terminal" },
    { text: "hi", origin: "agent" },
    { text: "hi", origin: "" },
    { text: "hi", origin: 42 },
    { text: "hi", origin: ["panel"] },
    { text: "hi", origin: null },
  ]) {
    const result = validateSendBody(body);
    assert.equal(result.ok, false, `body ${JSON.stringify(body)} is rejected`);
    assert.equal(typeof result.error, "string", "the rejection carries a message");
  }
});

test("validateSendBody rejects a missing, empty, or non-string text", () => {
  // A prompt that is not a non-empty string cannot be typed into a pane, and
  // sending an empty prompt would press Enter on whatever the shell last had.
  for (const body of [
    undefined,
    null,
    {},
    { text: undefined },
    { text: null },
    { text: "" },
    { text: 42 },
    { text: ["hi"] },
    { text: { prompt: "hi" } },
  ]) {
    const result = validateSendBody(body);
    assert.equal(result.ok, false, `body ${JSON.stringify(body)} is rejected`);
    assert.equal(typeof result.error, "string", "the rejection carries a message");
  }
});

test("validateSendBody does not trim or otherwise alter the text", () => {
  // The prompt is the agent's own input, byte for byte; whitespace and
  // newlines can be part of what the user meant to send.
  assert.deepEqual(validateSendBody({ text: "  hi \n" }), { ok: true, text: "  hi \n", origin: null });
});

test("sendPromptCalls types the text literally, then presses Enter", () => {
  // Two calls, in that order: `-l` sends the characters literally so a prompt
  // is never read as a list of key names, and Enter must be a separate call
  // because `-l` would send the word "Enter" as literal text.
  assert.deepEqual(sendPromptCalls("%3", "fix the flaky test"), [
    ["send-keys", "-t", "%3", "-l", "--", "fix the flaky test"],
    ["send-keys", "-t", "%3", "Enter"],
  ]);
});

test("a prompt that looks like tmux keys or options is still typed literally", () => {
  assert.deepEqual(sendPromptCalls("%7", "-C -- Enter"), [
    ["send-keys", "-t", "%7", "-l", "--", "-C -- Enter"],
    ["send-keys", "-t", "%7", "Enter"],
  ]);
});
