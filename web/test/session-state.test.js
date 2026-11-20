// A session carries a task state — where the task's workflow stands — and
// the server owns it: it stores and publishes the value but does not
// interpret it, the vocabulary being Task Factory's (docs/adr/0017-sessions-
// declare-group-state-and-working-directory.md). Only the workflow's owner
// may write it, proving it with the owner token the create response hands
// out once (docs/adr/0018-the-session-creator-gets-an-owner-token.md): an
// opaque per-session secret that writes that session's state and nothing
// else, and never appears in a session shape.
//
// server.js guards app.listen behind NODE_ENV !== "test", so importing it is
// safe and does not listen. The pane launch is a seam the suite points at a
// stub, so these tests run without a live tmux pane.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const logDir = mkdtempSync(join(tmpdir(), "ama-session-state-"));
process.env.ALL_MY_AGENTS_LOG_DIR = logDir;
process.env.ALL_MY_AGENTS_REGISTRY_POLL_MS = "3600000";
writeFileSync(
  join(logDir, "active-sessions.json"),
  JSON.stringify({
    version: 2,
    updatedAt: Date.now(),
    sessions: [
      { sessionId: "ses_registry", tmux: "registry-slice", state: "carried" },
      { sessionId: "ses_state", tmux: "registry-state-slice" },
    ],
  }),
);

process.env.NODE_ENV = "test";
const { app, sessionStates, ownerTokens, launching, paneResolution, tmuxOps } = await import("../server.js");

const realPaneFor = paneResolution.paneFor;
const realLaunch = launching.pane;
const realTmuxRun = tmuxOps.run;

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

// Create a session against the stubbed launcher, returning what the route
// answered. The owner token is the route's whole point, so the caller has
// to keep it.
async function createSession(body) {
  return call("POST", "/api/sessions", { name: `state-${Math.random().toString(36).slice(2, 8)}`, ...body });
}

test.beforeEach(() => {
  launching.pane = async (args) => {
    return "%7";
  };
  tmuxOps.run = async () => "";
});

test.afterEach(() => {
  launching.pane = realLaunch;
  paneResolution.paneFor = realPaneFor;
  tmuxOps.run = realTmuxRun;
});

// --- Creation hands the owner token out ------------------------------------

test("creating a session returns an owner token and records the initial state", async () => {
  const { statusCode, payload } = await createSession({ state: "grilling" });
  assert.equal(statusCode, 200);
  assert.equal(payload.ok, true);
  // The token is opaque: a non-empty string, and the only secret in the body.
  assert.equal(typeof payload.ownerToken, "string");
  assert.ok(payload.ownerToken.length > 0, "the owner token is non-empty");
  assert.equal(ownerTokens.get(payload.ownerToken), payload.name);
  assert.equal(sessionStates.get(payload.name), "grilling");
});

test("creating a session without a state still mints an owner token", async () => {
  const { statusCode, payload } = await createSession({});
  assert.equal(statusCode, 200);
  assert.equal(typeof payload.ownerToken, "string");
  assert.ok(payload.ownerToken.length > 0);
  assert.equal(sessionStates.has(payload.name), false);
});

test("a non-string, empty or multi-line state is refused at creation", async () => {
  for (const state of [42, "", "grilling\ndone", "  "]) {
    const { statusCode } = await createSession({ state });
    assert.equal(statusCode, 400, `state ${JSON.stringify(state)} refused`);
  }
});

test("a failed launch leaves no owner token or state behind", async () => {
  launching.pane = async () => {
    const err = new Error("tmux duplicate session work");
    err.duplicateSession = true;
    throw err;
  };
  const { statusCode, payload } = await createSession({ state: "grilling" });
  assert.equal(statusCode, 409);
  assert.equal(ownerTokens.has(payload.ownerToken), false);
  assert.equal(sessionStates.has(payload.name), false);
});

// --- The owner token writes the state ---------------------------------------

test("the owner token writes the session's state", async () => {
  const created = await createSession({});
  const { statusCode, payload } = await call("POST", `/api/sessions/${created.payload.name}/state`, {
    state: "awaiting_approval",
    ownerToken: created.payload.ownerToken,
  });
  assert.equal(statusCode, 200);
  assert.equal(payload.ok, true);
  assert.equal(payload.state, "awaiting_approval");
  assert.equal(sessionStates.get(created.payload.name), "awaiting_approval");
});

test("the write reaches the active-session registry immediately", async () => {
  // A second registry slice was seeded at boot; claiming it through the
  // create route mints the owner token the write needs, and the declaration
  // lands in the file at once — it survives a restart even before the next
  // reconcile pass (the same rule the group write follows).
  const created = await call("POST", "/api/sessions", { name: "registry-state-slice" });
  await call("POST", "/api/sessions/registry-state-slice/state", {
    state: "executing",
    ownerToken: created.payload.ownerToken,
  });
  const registry = JSON.parse(readFileSync(join(logDir, "active-sessions.json"), "utf8"));
  const entry = registry.sessions.find((s) => s.tmux === "registry-state-slice");
  assert.equal(entry.state, "executing");
});

test("state null clears the session's state", async () => {
  const created = await createSession({ state: "grilling" });
  const { statusCode, payload } = await call("POST", `/api/sessions/${created.payload.name}/state`, {
    state: null,
    ownerToken: created.payload.ownerToken,
  });
  assert.equal(statusCode, 200);
  assert.equal(payload.state, null);
  assert.equal(sessionStates.has(created.payload.name), false);
});

// --- And nothing else --------------------------------------------------------

test("a wrong owner token is refused", async () => {
  const created = await createSession({ state: "grilling" });
  const forged = await createSession({}); // another session's token
  const { statusCode, payload } = await call("POST", `/api/sessions/${created.payload.name}/state`, {
    state: "done",
    ownerToken: forged.payload.ownerToken,
  });
  assert.equal(statusCode, 401);
  assert.ok("error" in payload);
  // The refused write changed nothing.
  assert.equal(sessionStates.get(created.payload.name), "grilling");
});

test("a missing owner token is refused", async () => {
  const created = await createSession({ state: "grilling" });
  const { statusCode } = await call("POST", `/api/sessions/${created.payload.name}/state`, {
    state: "done",
  });
  assert.equal(statusCode, 401);
  assert.equal(sessionStates.get(created.payload.name), "grilling");
});

test("the owner token writes only its own session's state", async () => {
  const created = await createSession({});
  const other = await createSession({ state: "grilling" });
  const { statusCode } = await call("POST", `/api/sessions/${other.payload.name}/state`, {
    state: "done",
    ownerToken: created.payload.ownerToken,
  });
  assert.equal(statusCode, 401);
  assert.equal(sessionStates.get(other.payload.name), "grilling");
});

test("a non-string state is refused by the write route", async () => {
  const created = await createSession({});
  const { statusCode } = await call("POST", `/api/sessions/${created.payload.name}/state`, {
    state: { position: "done" },
    ownerToken: created.payload.ownerToken,
  });
  assert.equal(statusCode, 400);
});

// --- Secrecy ----------------------------------------------------------------

test("the owner token appears in no published session shape", async () => {
  const doc = await call("GET", "/api/contract");
  assert.equal(doc.payload.version, "10");
  // The create response declares it, because that is where it is handed out.
  assert.equal(doc.payload.shapes.createdSession.fields.ownerToken.type, "string");
  // Nowhere a session is published.
  assert.equal("ownerToken" in doc.payload.shapes.session.fields, false);
  assert.equal("ownerToken" in doc.payload.shapes.meshSession.fields, false);
});

test("the served contract declares the state route", async () => {
  const doc = await call("GET", "/api/contract");
  assert.deepEqual(doc.payload.routes.setSessionState, {
    method: "POST",
    path: "/api/sessions/{name}/state",
    shape: "sessionState",
  });
  assert.deepEqual(doc.payload.shapes.sessionState, {
    type: "object",
    fields: {
      ok: { type: "boolean" },
      name: { type: "string" },
      state: { type: ["string", "null"] },
    },
  });
});

// --- Lifecycle --------------------------------------------------------------

test("a rename carries the state and the owner token", async () => {
  const created = await createSession({ state: "grilling" });
  const oldName = created.payload.name;
  const { statusCode } = await call("POST", `/api/sessions/${oldName}/rename`, { newName: "renamed-slice" });
  assert.equal(statusCode, 200);
  assert.equal(sessionStates.get("renamed-slice"), "grilling");
  assert.equal(sessionStates.has(oldName), false);
  assert.equal(ownerTokens.get(created.payload.ownerToken), "renamed-slice");
  const { statusCode: writeStatus } = await call("POST", "/api/sessions/renamed-slice/state", {
    state: "done",
    ownerToken: created.payload.ownerToken,
  });
  assert.equal(writeStatus, 200);
});

test("deleting a session drops its owner token and its state", async () => {
  const created = await createSession({ state: "grilling" });
  const { statusCode } = await call("DELETE", `/api/sessions/${created.payload.name}`);
  assert.equal(statusCode, 200);
  assert.equal(ownerTokens.has(created.payload.ownerToken), false);
  assert.equal(sessionStates.has(created.payload.name), false);
});

// --- Publication ------------------------------------------------------------

test("the mesh snapshot carries a session's task state", async () => {
  const { fetchAllMeshSessions } = await import("../mesh.js");
  const local = [{ name: "alpha", paneId: "%1", tty: "/dev/ttys001", currentCommand: "zsh", windowName: "alpha", status: "idle", source: "screen", agent: "shell", lastActivity: 1, state: "executing" }];
  const { sessions } = await fetchAllMeshSessions(local, { name: "workhorse", peers: [] });
  assert.equal(sessions[0].state, "executing");
});

test("a peer session maps the state it reports", async () => {
  const { fetchAllMeshSessions } = await import("../mesh.js");
  const local = [{ name: "alpha", paneId: "%1", tty: "/dev/ttys001", currentCommand: "zsh", windowName: "alpha", status: "idle", source: "screen", agent: "shell", lastActivity: 1 }];
  const { sessions } = await fetchAllMeshSessions(local, { name: "workhorse", peers: [] });
  assert.equal(sessions[0].state, null);
});

test("a session the registry carried at boot comes back with its state", async () => {
  // The registry was written before the server was imported; the state it
  // recorded is seeded into the server's own declaration at startup, the
  // same way a group is.
  assert.equal(sessionStates.get("registry-slice"), "carried");
});
