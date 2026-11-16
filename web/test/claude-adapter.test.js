import { test } from "node:test";
import assert from "node:assert/strict";

import {
  HOOK_EVENT_MAP,
  mapHookEvent,
  resolveToken,
  resolveBaseUrl,
  assistantMessage,
  messageFor,
  buildBody,
} from "../integrations/claude/ama-status-hook.js";

test("maps the plain Claude hook events to the canonical vocabulary", () => {
  assert.equal(mapHookEvent({ hook_event_name: "SessionStart" }), "sessionStart");
  assert.equal(mapHookEvent({ hook_event_name: "UserPromptSubmit" }), "promptSubmit");
  assert.equal(mapHookEvent({ hook_event_name: "PostToolUse", tool_name: "Bash" }), "toolEnd");
  assert.equal(mapHookEvent({ hook_event_name: "Notification" }), "notification");
  assert.equal(mapHookEvent({ hook_event_name: "Stop" }), "stop");
  assert.equal(mapHookEvent({ hook_event_name: "SessionEnd" }), "sessionEnd");
});

test("a normal tool call is telemetry (toolStart)", () => {
  assert.equal(mapHookEvent({ hook_event_name: "PreToolUse", tool_name: "Bash" }), "toolStart");
  assert.equal(mapHookEvent({ hook_event_name: "PreToolUse", tool_name: "Edit" }), "toolStart");
});

test("PreToolUse on a prompt tool means the agent is blocked on the user", () => {
  assert.equal(
    mapHookEvent({ hook_event_name: "PreToolUse", tool_name: "AskUserQuestion" }),
    "permissionRequest",
  );
  assert.equal(
    mapHookEvent({ hook_event_name: "PreToolUse", tool_name: "ExitPlanMode" }),
    "permissionRequest",
  );
});

test("an explicit PermissionRequest hook maps to permissionRequest", () => {
  assert.equal(mapHookEvent({ hook_event_name: "PermissionRequest" }), "permissionRequest");
});

test("events with no canonical equivalent are ignored, not guessed", () => {
  assert.equal(mapHookEvent({ hook_event_name: "SubagentStop" }), null);
  assert.equal(mapHookEvent({ hook_event_name: "PreCompact" }), null);
  assert.equal(mapHookEvent({ hook_event_name: "PostCompact" }), null);
  assert.equal(mapHookEvent({}), null);
  assert.equal(mapHookEvent(null), null);
});

test("token comes from the pane environment", () => {
  assert.equal(resolveToken({ AMA_SURFACE_TOKEN: "abc123" }), "abc123");
  assert.equal(resolveToken({}), null);
  assert.equal(resolveToken(undefined), null);
});

test("base url prefers ALL_MY_AGENTS_URL, then PORT, then 3456", () => {
  assert.equal(resolveBaseUrl({ ALL_MY_AGENTS_URL: "http://host:9/" }), "http://host:9");
  assert.equal(resolveBaseUrl({ ALL_MY_AGENTS_PORT: "4000" }), "http://127.0.0.1:4000");
  assert.equal(resolveBaseUrl({}), "http://127.0.0.1:3456");
});

test("the body carries the surface token and never Claude's own session id", () => {
  assert.deepEqual(buildBody("working", "tok_1"), { event: "working", surfaceToken: "tok_1" });
  const body = buildBody("toolStart", "tok_2");
  assert.equal("sessionId" in body, false);
  assert.equal("session_id" in body, false);
});

test("a Stop hook's final response is carried as the message", () => {
  const text = "The build passes and the tests are green.";
  assert.equal(assistantMessage({ last_assistant_message: text }), text);
});

test("a Stop hook with nothing to say carries no message", () => {
  // Claude's Stop payload always has the field per its docs, but a hook must
  // never invent content out of an empty, missing or malformed field.
  assert.equal(assistantMessage({}), null);
  assert.equal(assistantMessage({ last_assistant_message: "" }), null);
  assert.equal(assistantMessage({ last_assistant_message: "   " }), null);
  assert.equal(assistantMessage({ last_assistant_message: 42 }), null);
  assert.equal(assistantMessage(null), null);
});

test("only the stop event carries the final response", () => {
  // SubagentStop also has last_assistant_message, but it does not map to a
  // canonical event and is ignored; a prompt or tool event is not the reply.
  assert.equal(messageFor("stop", { last_assistant_message: "the reply" }), "the reply");
  assert.equal(messageFor("stop", {}), null);
  assert.equal(messageFor("toolStart", { last_assistant_message: "the reply" }), null);
  assert.equal(messageFor("stop", null), null);
});

test("the POST body carries the message text when there is one", () => {
  assert.deepEqual(
    buildBody("stop", "tok_3", "the reply"),
    { event: "stop", surfaceToken: "tok_3", message: "the reply" },
  );
  assert.deepEqual(buildBody("stop", "tok_3", null), { event: "stop", surfaceToken: "tok_3" });
  assert.deepEqual(buildBody("stop", "tok_3"), { event: "stop", surfaceToken: "tok_3" });
});

test("the mapping table is exactly the canonical set Claude can produce", () => {
  assert.deepEqual(HOOK_EVENT_MAP, {
    SessionStart: "sessionStart",
    UserPromptSubmit: "promptSubmit",
    PreToolUse: "toolStart",
    PostToolUse: "toolEnd",
    PermissionRequest: "permissionRequest",
    Notification: "notification",
    Stop: "stop",
    SessionEnd: "sessionEnd",
  });
});