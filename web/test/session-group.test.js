// A session carries the group it belongs to and the directory its pane runs
// in, and the server is the one that says it (docs/adr/0017-sessions-declare-
// group-state-and-working-directory.md). POST /api/sessions accepts an
// optional `dir` and `group`; membership is server-declared, so the agent
// event route refuses both.
//
// server.js guards app.listen behind NODE_ENV !== "test", so importing it is
// safe and does not listen. The pane launch is a seam the suite points at a
// stub, so these tests run without a live tmux pane.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const logDir = mkdtempSync(join(tmpdir(), "ama-session-group-"));
process.env.ALL_MY_AGENTS_LOG_DIR = logDir;
process.env.ALL_MY_AGENTS_REGISTRY_POLL_MS = "3600000";
writeFileSync(
  join(logDir, "active-sessions.json"),
  JSON.stringify({
    version: 2,
    updatedAt: Date.now(),
    sessions: [
      { sessionId: "ses_registry", tmux: "registry-slice", group: "Carried" },
    ],
  }),
);

process.env.NODE_ENV = "test";
const { app, sessionGroups, launching, paneResolution } = await import("../server.js");

const realPaneFor = paneResolution.paneFor;
const realLaunch = launching.pane;
const launched = [];

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

test.beforeEach(() => {
  launched.length = 0;
  launching.pane = async (args) => {
    launched.push(args);
    return "%7";
  };
});

test.afterEach(() => {
  launching.pane = realLaunch;
  paneResolution.paneFor = realPaneFor;
});

test("creating a session with a directory and a group records both", async () => {
  const { statusCode, payload } = await call("POST", "/api/sessions", {
    name: "task-slice",
    dir: "/repos/task-factory",
    group: "Task Factory",
  });
  assert.equal(statusCode, 200);
  assert.equal(payload.ok, true);
  assert.equal(launched.length, 1);
  assert.equal(launched[0].dir, "/repos/task-factory");
  assert.equal(sessionGroups.get("task-slice"), "Task Factory");
});

test("creating a session with neither behaves as before", async () => {
  const { statusCode, payload } = await call("POST", "/api/sessions", { name: "plain-slice" });
  assert.equal(statusCode, 200);
  assert.equal(payload.ok, true);
  assert.equal(launched[0].dir, undefined);
  assert.equal(sessionGroups.has("plain-slice"), false);
});

test("a relative directory is refused", async () => {
  const { statusCode } = await call("POST", "/api/sessions", { name: "bad-dir", dir: "repos/x" });
  assert.equal(statusCode, 400);
});

test("a directory is a single line", async () => {
  const { statusCode } = await call("POST", "/api/sessions", { name: "bad-dir", dir: "/repos/a\nb" });
  assert.equal(statusCode, 400);
});

test("a group name that cannot be an object key is refused", async () => {
  const { statusCode } = await call("POST", "/api/sessions", { name: "bad-group", group: "__proto__" });
  assert.equal(statusCode, 400);
});

test("an explicit null dir and group mean neither", async () => {
  const { statusCode } = await call("POST", "/api/sessions", { name: "nulls-slice", dir: null, group: null });
  assert.equal(statusCode, 200);
  assert.equal(launched[0].dir, undefined);
  assert.equal(sessionGroups.has("nulls-slice"), false);
});

test("a failed launch leaves no group behind", async () => {
  launching.pane = async () => {
    const err = new Error("tmux duplicate session work");
    err.duplicateSession = true;
    throw err;
  };
  const { statusCode } = await call("POST", "/api/sessions", { name: "dup-slice", group: "Work" });
  assert.equal(statusCode, 409);
  assert.equal(sessionGroups.has("dup-slice"), false);
});

// Membership is server-declared: the agent's event channel must not accept it.
test("the event route refuses a group", async () => {
  const { statusCode, payload } = await call("POST", "/api/events", { event: "stop", group: "Work" });
  assert.equal(statusCode, 400);
  assert.match(payload.error, /group/);
});

test("the event route refuses a directory", async () => {
  const { statusCode, payload } = await call("POST", "/api/events", { event: "stop", dir: "/tmp" });
  assert.equal(statusCode, 400);
  assert.match(payload.error, /dir/);
});

test("the event route refuses state", async () => {
  const { statusCode, payload } = await call("POST", "/api/events", { event: "stop", state: "done" });
  assert.equal(statusCode, 400);
  assert.match(payload.error, /state/);
});

test("the mesh snapshot carries a session's group and directory", async () => {
  const { fetchAllMeshSessions } = await import("../mesh.js");
  const local = [{ name: "alpha", paneId: "%1", tty: "/dev/ttys001", currentCommand: "zsh", windowName: "alpha", status: "idle", source: "screen", agent: "shell", lastActivity: 1, group: "Work", dir: "/repos/x" }];
  const { sessions } = await fetchAllMeshSessions(local, { name: "workhorse", peers: [] });
  assert.equal(sessions[0].group, "Work");
  assert.equal(sessions[0].dir, "/repos/x");
});

test("a peer session maps the group and directory it reports", async () => {
  const { fetchAllMeshSessions } = await import("../mesh.js");
  const local = [{ name: "alpha", paneId: "%1", tty: "/dev/ttys001", currentCommand: "zsh", windowName: "alpha", status: "idle", source: "screen", agent: "shell", lastActivity: 1 }];
  const { sessions } = await fetchAllMeshSessions(local, { name: "workhorse", peers: [] });
  assert.equal(sessions[0].group, null);
  assert.equal(sessions[0].dir, null);
});
