// The task channel's contract.
//
// A task is free text an agent reports about itself. The server trims it and
// caps its length; both apps carry it verbatim and escape it at the point of
// rendering. The cases live in contract/task-update.json because the wire
// tasks are shared: the web suite and the Swift suite must agree on what
// crosses the wire.
//
// The canonicalisation cases are asserted here against web/task.js; the wire
// tasks are asserted here and in Tests/AllMyAgentsTests/TaskContractTests.swift.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { applyTaskUpdate, canonicalTask, TASK_MAX_LENGTH } from "../task.js";
import { taskHtml } from "../public/session-task.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(
  readFileSync(join(here, "..", "..", "contract", "task-update.json"), "utf8"),
);

// --- The canonicalisation the server applies --------------------------------

test("every canonicalisation case in the fixture resolves the way the fixture says", () => {
  for (const c of fixture.cases) {
    if (c.inputLength) continue;
    const input = c.input ?? {};
    const update = applyTaskUpdate(input.task, null);
    assert.deepEqual(update, c.expected, `case: ${c.name}`);
  }
});

test("the rules the fixture states are the rules the server applies", () => {
  assert.equal(fixture.rules.maxLength, TASK_MAX_LENGTH);
  assert.equal(fixture.rules.trim, true);
  assert.equal(fixture.rules.emptyIsNull, true);
  assert.equal(fixture.rules.absentKeepsPrevious, true);
});

test("a task longer than the cap is truncated to the cap", () => {
  const c = fixture.cases.find((c) => c.inputLength);
  assert.ok(c, "the fixture has a length case");
  const update = applyTaskUpdate("x".repeat(c.inputLength), null);
  assert.equal(update.effect, "set");
  assert.equal(update.task.length, c.expected.taskLength);
  assert.equal(update.task.length, TASK_MAX_LENGTH);
  assert.ok(update.task.endsWith("..."), "a truncated task says so");
});

test("a task that is exactly the cap is left alone", () => {
  const exact = "y".repeat(TASK_MAX_LENGTH);
  assert.equal(canonicalTask(exact), exact);
});

test("an update that carries no task keeps the task already recorded", () => {
  assert.deepEqual(applyTaskUpdate(undefined, "Build feature X"), {
    task: "Build feature X",
    effect: "keep",
  });
});

test("a value that is not a string is not a task", () => {
  assert.equal(canonicalTask({ a: 1 }), null);
  assert.equal(canonicalTask(42), null);
  assert.equal(canonicalTask(["a"]), null);
});

// --- The wire ---------------------------------------------------------------

test("every wire task crosses the wire verbatim", () => {
  for (const task of fixture.wireTasks) {
    assert.equal(canonicalTask(task), task, `task: ${task}`);
  }
});

// --- The renderer ------------------------------------------------------------

test("the renderer escapes every wire task", () => {
  for (const task of fixture.wireTasks) {
    const html = taskHtml(task);
    const inner = html
      .replace(/^<span class="session-task">/, "")
      .replace(/<\/span>$/, "");
    assert.ok(
      !/[<>"']/.test(inner),
      `a task must not carry raw markup into the tile: ${task}`,
    );
  }
});

test("a script tag in a task cannot escape the tile", () => {
  const html = taskHtml('<script>alert(1)</script>');
  assert.ok(!html.includes("<script"), "the tile carries no script tag");
  assert.ok(html.includes("&lt;script&gt;"), "the task is escaped instead");
});

test("a session with no task renders no task", () => {
  assert.equal(taskHtml(null), "");
  assert.equal(taskHtml(undefined), "");
  assert.equal(taskHtml(""), "");
});

// --- The server --------------------------------------------------------------
//
// server.js guards app.listen behind NODE_ENV !== "test", so importing it is
// safe and does not listen. The pane lookup it uses is a seam the suite
// points at a stub, so these tests run without a live tmux pane.

// The registry a session id is resolved against is read from disk at boot,
// so the test points the log directory at a temporary one and writes a
// registry there before the server is imported.
const logDir = mkdtempSync(join(tmpdir(), "ama-task-"));
process.env.ALL_MY_AGENTS_LOG_DIR = logDir;
process.env.ALL_MY_AGENTS_REGISTRY_POLL_MS = "3600000";
writeFileSync(
  join(logDir, "active-sessions.json"),
  JSON.stringify({
    version: 2,
    updatedAt: Date.now(),
    sessions: [{ sessionId: "ses_task_registry", tmux: "registry-slice" }],
  }),
);

process.env.NODE_ENV = "test";
const { app, surfaceTokens, paneResolution } = await import("../server.js");

const realPaneFor = paneResolution.paneFor;
const livePane = async () => "%9";

function call(method, url, body) {
  return new Promise((resolve) => {
    const res = {
      statusCode: 200,
      set() { return this; },
      setHeader() { return this; },
      status(code) { this.statusCode = code; return this; },
      json(payload) { resolve({ statusCode: this.statusCode, payload }); return this; },
    };
    app({ method, url, headers: {}, body }, res);
  });
}

async function postEvent(body) {
  surfaceTokens.set("tok-task", "task-slice");
  paneResolution.paneFor = livePane;
  try {
    return await call("POST", "/api/events", { event: "stop", surfaceToken: "tok-task", ...body });
  } finally {
    surfaceTokens.delete("tok-task");
    paneResolution.paneFor = realPaneFor;
  }
}

async function postEventRaw(body) {
  paneResolution.paneFor = livePane;
  try {
    return await call("POST", "/api/events", body);
  } finally {
    paneResolution.paneFor = realPaneFor;
  }
}

test("an event that carries a task is acknowledged with it", async () => {
  const { statusCode, payload } = await postEvent({ task: "Build feature X" });
  assert.equal(statusCode, 200);
  assert.equal(payload.task, "Build feature X");
});

test("a task that is not a string is refused", async () => {
  const { statusCode, payload } = await postEvent({ task: { a: 1 } });
  assert.equal(statusCode, 400);
  assert.ok("error" in payload);
});

test("the server caps the task it accepts", async () => {
  const { statusCode, payload } = await postEvent({ task: "z".repeat(400) });
  assert.equal(statusCode, 200);
  assert.equal(payload.task.length, TASK_MAX_LENGTH);
});

test("an event without a task keeps the task the session already had", async () => {
  await postEvent({ task: "Build feature X" });
  const { statusCode, payload } = await postEvent({});
  assert.equal(statusCode, 200);
  assert.equal(payload.task, "Build feature X");
});

test("an explicit null clears the task", async () => {
  await postEvent({ task: "Build feature X" });
  const { statusCode, payload } = await postEvent({ task: null });
  assert.equal(statusCode, 200);
  assert.equal(payload.task, null);
});

// A registry session id is not a secret — it is readable from the
// unauthenticated GET /api/registry — so it must not authorise a task.
test("a task reported with only a registry session id is refused", async () => {
  const { statusCode, payload } = await postEventRaw({
    event: "stop",
    sessionId: "ses_task_registry",
    task: "Spoofed task",
  });
  assert.equal(statusCode, 403);
  assert.ok("error" in payload);
});

test("a task reported with a token that is not this session's is refused", async () => {
  const { statusCode, payload } = await postEventRaw({
    event: "stop",
    sessionId: "ses_task_registry",
    surfaceToken: "tok-not-this-session",
    task: "Spoofed task",
  });
  assert.equal(statusCode, 403);
  assert.ok("error" in payload);
});

test("a status event with only a registry session id is still accepted", async () => {
  const { statusCode, payload } = await postEventRaw({
    event: "stop",
    sessionId: "ses_task_registry",
  });
  assert.equal(statusCode, 200);
  assert.equal(payload.ok, true);
});
