import { test } from "node:test";
import assert from "node:assert/strict";

import { AmaStatusPlugin } from "../integrations/opencode/ama-status.js";

const {
  canonicalBusEvent,
  sessionIdFromBusProps,
  resolveBaseUrl,
  resolveToken,
  buildBody,
  assistantText,
  createReplyTracker,
  HOOK_EVENTS,
} = AmaStatusPlugin.helpers;

test("bus events map to the canonical status vocabulary", () => {
  assert.equal(canonicalBusEvent("session.created"), "sessionStart");
  assert.equal(canonicalBusEvent("session.idle"), "stop");
  assert.equal(canonicalBusEvent("session.deleted"), "sessionEnd");
  assert.equal(canonicalBusEvent("permission.updated"), "permissionRequest");
  assert.equal(canonicalBusEvent("permission.asked"), "permissionRequest");
});

test("unrelated bus events are ignored", () => {
  assert.equal(canonicalBusEvent("message.updated"), null);
  assert.equal(canonicalBusEvent("message.part.updated"), null);
  assert.equal(canonicalBusEvent("session.status"), null);
  assert.equal(canonicalBusEvent(undefined), null);
});

test("hook names map to the canonical status vocabulary", () => {
  assert.equal(HOOK_EVENTS["chat.message"], "promptSubmit");
  assert.equal(HOOK_EVENTS["tool.execute.before"], "toolStart");
  assert.equal(HOOK_EVENTS["tool.execute.after"], "toolEnd");
  assert.equal(HOOK_EVENTS["permission.ask"], "permissionRequest");
});

test("session id is read from a plain session event", () => {
  assert.equal(
    sessionIdFromBusProps({ type: "session.idle", properties: { sessionID: "ses_a" } }),
    "ses_a"
  );
});

test("session id is read from session.created / session.deleted info", () => {
  assert.equal(
    sessionIdFromBusProps({ type: "session.created", properties: { info: { id: "ses_b" } } }),
    "ses_b"
  );
  assert.equal(
    sessionIdFromBusProps({ type: "session.deleted", properties: { info: { id: "ses_b" } } }),
    "ses_b"
  );
});

test("session id is read from message and part payloads", () => {
  assert.equal(
    sessionIdFromBusProps({ type: "message.updated", properties: { info: { sessionID: "ses_c" } } }),
    "ses_c"
  );
  assert.equal(
    sessionIdFromBusProps({
      type: "message.part.updated",
      properties: { part: { sessionID: "ses_d" } },
    }),
    "ses_d"
  );
});

test("session id is read from a permission event", () => {
  assert.equal(
    sessionIdFromBusProps({ type: "permission.updated", properties: { sessionID: "ses_e" } }),
    "ses_e"
  );
});

test("a payload with no session id yields null", () => {
  assert.equal(sessionIdFromBusProps({ type: "session.idle", properties: {} }), null);
  assert.equal(sessionIdFromBusProps({ type: "session.idle" }), null);
  assert.equal(sessionIdFromBusProps(undefined), null);
});

test("base url prefers an explicit AMA url", () => {
  assert.equal(resolveBaseUrl({ ALL_MY_AGENTS_URL: "http://host:9999/" }), "http://host:9999");
});

test("base url falls back to the AMA port", () => {
  assert.equal(resolveBaseUrl({ ALL_MY_AGENTS_PORT: "4000" }), "http://127.0.0.1:4000");
});

test("base url defaults to the standard AMA port", () => {
  assert.equal(resolveBaseUrl({}), "http://127.0.0.1:3456");
});

test("the module exposes exactly one plugin function for the loader", async () => {
  assert.equal(typeof AmaStatusPlugin, "function");
});
test("the surface token is read from the pane environment", () => {
  assert.equal(resolveToken({ AMA_SURFACE_TOKEN: "abc123" }), "abc123");
  assert.equal(resolveToken({}), null);
  assert.equal(resolveToken({ AMA_SURFACE_TOKEN: "" }), null);
  assert.equal(resolveToken(undefined), null);
});

test("the event body carries the surface token when there is one", () => {
  assert.deepEqual(buildBody("working", "ses_1", "abc123"), {
    event: "working",
    sessionId: "ses_1",
    surfaceToken: "abc123",
  });
});

test("the event body omits the surface token when there is none", () => {
  assert.deepEqual(buildBody("working", "ses_1", null), {
    event: "working",
    sessionId: "ses_1",
  });
});

test("an assistant message's text parts become the reply", () => {
  const info = {
    role: "assistant",
    parts: [
      { type: "text", text: "here is" },
      { type: "tool", tool: "bash", state: { status: "completed" } },
      { type: "text", text: "the answer" },
    ],
  };
  assert.equal(assistantText(info), "here is\n\nthe answer");
});

test("a message with nothing to say carries no reply", () => {
  assert.equal(assistantText({ role: "user", parts: [{ type: "text", text: "hi" }] }), null);
  assert.equal(assistantText({ role: "assistant", parts: [] }), null);
  assert.equal(assistantText({ role: "assistant", parts: [{ type: "text", text: "   " }] }), null);
  assert.equal(assistantText({}), null);
  assert.equal(assistantText(undefined), null);
});

test("the tracker remembers the last assistant reply from message.updated", () => {
  const tracker = createReplyTracker();
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_1",
      info: { role: "assistant", parts: [{ type: "text", text: "the reply" }] },
    },
  });
  assert.equal(tracker.take("ses_1"), "the reply");
});

test("the tracker's reply is taken once, then forgotten", () => {
  const tracker = createReplyTracker();
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_1",
      info: { role: "assistant", parts: [{ type: "text", text: "the reply" }] },
    },
  });
  assert.equal(tracker.take("ses_1"), "the reply");
  assert.equal(tracker.take("ses_1"), null);
});

test("the tracker keeps sessions apart", () => {
  const tracker = createReplyTracker();
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_1",
      info: { role: "assistant", parts: [{ type: "text", text: "for one" }] },
    },
  });
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_2",
      info: { role: "assistant", parts: [{ type: "text", text: "for two" }] },
    },
  });
  assert.equal(tracker.take("ses_2"), "for two");
  assert.equal(tracker.take("ses_1"), "for one");
});

test("user messages and unknown sessions carry no reply", () => {
  const tracker = createReplyTracker();
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_1",
      info: { role: "user", parts: [{ type: "text", text: "the prompt" }] },
    },
  });
  assert.equal(tracker.take("ses_1"), null);
  assert.equal(tracker.take("ses_9"), null);
});

test("the tracker forgets a session on request", () => {
  const tracker = createReplyTracker();
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_1",
      info: { role: "assistant", parts: [{ type: "text", text: "the reply" }] },
    },
  });
  tracker.forget("ses_1");
  assert.equal(tracker.take("ses_1"), null);
});

test("the tracker reads the reply from a text part on opencode 1.19 and later", () => {
  // 1.19 and later do not carry the text inside the message: the message
  // says it is the agent's, and the text arrives as a part of it.
  const tracker = createReplyTracker();
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_1",
      info: { id: "msg_1", role: "assistant" },
    },
  });
  tracker.observe({
    type: "message.part.updated",
    properties: {
      sessionID: "ses_1",
      part: { id: "prt_1", messageID: "msg_1", type: "text", text: "the reply" },
    },
  });
  assert.equal(tracker.take("ses_1"), "the reply");
});

test("the tracker does not take the person's own text for a reply", () => {
  const tracker = createReplyTracker();
  tracker.observe({
    type: "message.updated",
    properties: {
      sessionID: "ses_1",
      info: { id: "msg_0", role: "user" },
    },
  });
  tracker.observe({
    type: "message.part.updated",
    properties: {
      sessionID: "ses_1",
      part: { id: "prt_0", messageID: "msg_0", type: "text", text: "the prompt" },
    },
  });
  assert.equal(tracker.take("ses_1"), null);
});

test("the stop event body carries the reply when there is one", () => {
  assert.deepEqual(buildBody("stop", "ses_1", "abc123", "the reply"), {
    event: "stop",
    sessionId: "ses_1",
    surfaceToken: "abc123",
    message: "the reply",
  });
});

test("the event body omits the message when there is none", () => {
  assert.deepEqual(buildBody("stop", "ses_1", "abc123", null), {
    event: "stop",
    sessionId: "ses_1",
    surfaceToken: "abc123",
  });
  assert.deepEqual(buildBody("working", "ses_1", "abc123"), {
    event: "working",
    sessionId: "ses_1",
    surfaceToken: "abc123",
  });
});
