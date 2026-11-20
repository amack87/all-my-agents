// The published API contract, read from `contract/api-contract.json` at the
// repo root. The server builds the served document from its own vocabulary
// and route table and serves it at GET /api/contract; the suite below asserts
// the document it serves matches this fixture, and that a route or a shape
// the contract publishes that the server does not serve is a loud failure
// rather than a quiet lie.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { STATUSES } from "../public/session-status.js";
import {
  routeTable,
  missingContractRoutes,
  checkShape,
  buildContractDocument,
  createShapeGuard,
  refuseToStartIfContractLies,
} from "../api-contract.js";

const here = dirname(fileURLToPath(import.meta.url));
const contractDir = join(here, "..", "..", "contract");
const contract = JSON.parse(readFileSync(join(contractDir, "api-contract.json"), "utf8"));
const vocabulary = JSON.parse(readFileSync(join(contractDir, "status-vocabulary.json"), "utf8"));

test("the contract carries a version, because it is a public surface", () => {
  assert.equal(typeof contract.version, "string");
  assert.ok(contract.version.length > 0, "the contract has a non-empty version");
});

test("the contract's vocabulary is the shared status vocabulary", () => {
  assert.deepEqual(contract.statuses.vocabulary, vocabulary.statuses);
  assert.deepEqual(contract.statuses.vocabulary, [...STATUSES]);
});

test("the contract declares which statuses mean working and which mean the turn is over", () => {
  for (const word of contract.statuses.working) {
    assert.ok(contract.statuses.vocabulary.includes(word), `"${word}" is in the vocabulary`);
  }
  for (const word of contract.statuses.turnOver) {
    assert.ok(contract.statuses.vocabulary.includes(word), `"${word}" is in the vocabulary`);
  }
});

test("every route the contract publishes declares a method, a path and a shape the contract defines", () => {
  const names = Object.keys(contract.routes);
  assert.ok(names.length > 0, "the contract publishes routes");
  for (const [name, route] of Object.entries(contract.routes)) {
    assert.ok(["GET", "POST", "WS"].includes(route.method), `${name}: method "${route.method}"`);
    assert.match(route.path, /^\//, `${name}: path starts with /`);
    assert.ok(contract.shapes[route.shape], `${name}: shape "${route.shape}" is defined`);
  }
});

// --- The server's real route table ---

function routeLayer(method, path) {
  return { route: { methods: { [method.toLowerCase()]: true }, path } };
}
function otherLayer(name) {
  return { name };
}

test("routeTable reads a router stack, ignoring layers that are not routes", () => {
  const app = {
    _router: {
      stack: [
        otherLayer("query"),
        otherLayer("expressInit"),
        otherLayer("jsonParser"),
        otherLayer("serveStatic"),
        routeLayer("get", "/api/sessions"),
        routeLayer("post", "/api/sessions"),
      ],
    },
  };
  assert.deepEqual(routeTable(app), [
    { method: "GET", path: "/api/sessions" },
    { method: "POST", path: "/api/sessions" },
  ]);
});

test("routeTable compares named parameters the way the contract writes them", () => {
  const app = { _router: { stack: [routeLayer("post", "/api/sessions/:name/rename")] } };
  assert.deepEqual(routeTable(app), [{ method: "POST", path: "/api/sessions/{name}/rename" }]);
});

test("routeTable reads an express-ws websocket route as a WS route", () => {
  // express-ws registers its websocket routes as GET /ws/status/.websocket;
  // a client subscribes to /ws/status, so that is what the table should say.
  const app = { _router: { stack: [routeLayer("get", "/ws/status/.websocket")] } };
  assert.deepEqual(routeTable(app), [{ method: "WS", path: "/ws/status" }]);
});

test("missingContractRoutes names what the contract publishes that the server does not serve", () => {
  const lying = {
    routes: {
      listSessions: { method: "GET", path: "/api/sessions", shape: "sessionList" },
      ghost: { method: "GET", path: "/api/ghost", shape: "sessionList" },
    },
  };
  const table = [{ method: "GET", path: "/api/sessions" }];
  assert.deepEqual(missingContractRoutes(lying, table), [
    { name: "ghost", method: "GET", path: "/api/ghost" },
  ]);
});

test("missingContractRoutes is empty when the contract tells the truth", () => {
  const table = [{ method: "GET", path: "/api/sessions" }, { method: "WS", path: "/ws/status" }];
  const honest = {
    routes: {
      listSessions: { method: "GET", path: "/api/sessions", shape: "sessionList" },
      statusFeed: { method: "WS", path: "/ws/status", shape: "statusFrame" },
    },
  };
  assert.deepEqual(missingContractRoutes(honest, table), []);
});

// --- Shape checking ---

const shapeCtx = { shapes: contract.shapes, vocabulary: contract.statuses.vocabulary };

function sessionFixture(overrides = {}) {
  return {
    name: "slice",
    paneId: "%0",
    tty: "/dev/ttys001",
    currentCommand: "zsh",
    windowName: "slice",
    status: "working",
    source: "screen",
    agent: "opencode",
    lastActivity: 1731542400,
    ...overrides,
  };
}

test("checkShape accepts a response that conforms to its declared shape", () => {
  assert.deepEqual(checkShape("session", sessionFixture(), shapeCtx), []);
  // Optional fields may be present or absent, but never mistyped.
  assert.deepEqual(
    checkShape("session", sessionFixture({ projectPath: "/tmp/x", summary: "hello" }), shapeCtx),
    [],
  );
  assert.deepEqual(
    checkShape("createdSession", { ok: true, name: "slice", command: null, ownerToken: "own-slice" }, shapeCtx),
    [],
  );
});

test("checkShape flags a declared field that is missing", () => {
  const { command: _omitted, ...short } = { ok: true, name: "slice", command: null, ownerToken: "own-slice" };
  const problems = checkShape("createdSession", short, shapeCtx);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /command/);
});

test("checkShape flags a declared field of the wrong type", () => {
  const problems = checkShape("createdSession", { ok: "yes", name: "slice", command: null, ownerToken: "own-slice" }, shapeCtx);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /ok/);
});

test("checkShape flags a field the shape does not declare", () => {
  // That is the point of publishing: a new field is a deliberate act.
  const problems = checkShape(
    "createdSession",
    { ok: true, name: "slice", command: null, ownerToken: "own-slice", surprise: 1 },
    shapeCtx,
  );
  assert.equal(problems.length, 1);
  assert.match(problems[0], /surprise/);
});

test("checkShape only accepts vocabulary words where the shape says vocabulary", () => {
  assert.deepEqual(
    checkShape("session", sessionFixture({ status: "needsInput" }), shapeCtx),
    [],
  );
  const problems = checkShape("session", sessionFixture({ status: "busy" }), shapeCtx);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /status/);
});

test("checkShape follows shape references and null unions", () => {
  const meshSession = { ...sessionFixture({ source: "event" }), machine: "local", machineHost: "local" };
  assert.deepEqual(
    checkShape("meshSnapshot", { sessions: [meshSession], peerStatus: { workhorse: "ok" } }, shapeCtx),
    [],
  );
  assert.deepEqual(
    checkShape(
      "eventAck",
      {
        ok: true,
        target: "%0",
        name: "slice",
        event: "turn_end",
        known: true,
        status: null,
        source: null,
        changed: false,
        messageId: null,
        task: null,
      },
      shapeCtx,
    ),
    [],
  );
});

test("checkShape checks arrays element by element", () => {
  const meshSession = { ...sessionFixture(), machine: "local", machineHost: "local" };
  const problems = checkShape("meshSnapshot", { sessions: [meshSession, { ...meshSession, status: "busy" }], peerStatus: {} }, shapeCtx);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /sessions\.1\.status|status/);
});

// --- Building the served document ---

test("the served document is built from the server's own vocabulary", () => {
  // The server passes its own word list in; the document carries it, so a
  // change to the server's vocabulary surfaces instead of being assumed.
  const table = Object.values(contract.routes).map(({ method, path }) => ({ method, path }));
  const doc = buildContractDocument(contract, table, ["alpha", "beta"]);
  assert.deepEqual(doc.statuses.vocabulary, ["alpha", "beta"]);
  // Everything else is still the fixture.
  assert.deepEqual(doc.routes, contract.routes);
});

test("the served document is built from the server's own route table", () => {
  // A route the contract publishes that the table does not serve is a
  // refusal to start, not a contract that lies.
  assert.throws(
    () => buildContractDocument(contract, [], contract.statuses.vocabulary),
    /\/api\/health/,
  );
});

test("the server refuses to start when the contract publishes a route it does not have", () => {
  let exitCode = null;
  const logged = [];
  refuseToStartIfContractLies(
    { routes: { ghost: { method: "GET", path: "/api/ghost", shape: "session" } } },
    [{ method: "GET", path: "/api/sessions" }],
    { exit: (code) => { exitCode = code; }, log: (...args) => logged.push(args) },
  );
  assert.equal(exitCode, 1);
  assert.match(JSON.stringify(logged), /\/api\/ghost/);
});

test("the server starts when the contract's routes are all served", () => {
  let exitCode = null;
  refuseToStartIfContractLies(
    { routes: { listSessions: { method: "GET", path: "/api/sessions", shape: "session" } } },
    [{ method: "GET", path: "/api/sessions" }],
    { exit: (code) => { exitCode = code; }, log: () => {} },
  );
  assert.equal(exitCode, null);
});

// --- The shape guard on live responses ---

import express from "express";

function call(app, method, url, { body, headers } = {}) {
  return new Promise((resolve) => {
    const res = {
      statusCode: 200,
      set() { return this; },
      setHeader() { return this; },
      status(code) { this.statusCode = code; return this; },
      json(payload) { resolve({ statusCode: this.statusCode, payload }); return this; },
      end() { resolve({ statusCode: this.statusCode, payload: undefined }); return this; },
    };
    app({ method, url, headers: headers ?? {}, body }, res);
  });
}

test("the shape guard stays quiet on a conforming response", async () => {
  const problems = [];
  const app = express();
  app.use(createShapeGuard(contract, contract.statuses.vocabulary, { onProblem: (p) => problems.push(p) }));
  app.post("/api/sessions", (_req, res) => res.json({ ok: true, name: "slice", command: null, ownerToken: "own-slice" }));
  const { payload } = await call(app, "POST", "/api/sessions");
  assert.deepEqual(payload, { ok: true, name: "slice", command: null, ownerToken: "own-slice" });
  assert.deepEqual(problems, []);
});

test("the shape guard surfaces a response that breaks its declared shape", async () => {
  const problems = [];
  const app = express();
  app.use(createShapeGuard(contract, contract.statuses.vocabulary, { onProblem: (p) => problems.push(...p) }));
  app.post("/api/sessions", (_req, res) => res.json({ ok: true, name: "slice", command: null, ownerToken: "own-slice", surprise: 1 }));
  await call(app, "POST", "/api/sessions");
  assert.equal(problems.length, 1);
  assert.match(problems[0], /surprise/);
});

test("the shape guard leaves undeclared routes and error responses alone", async () => {
  const problems = [];
  const app = express();
  app.use(createShapeGuard(contract, contract.statuses.vocabulary, { onProblem: (p) => problems.push(p) }));
  app.get("/api/undeclared", (_req, res) => res.json({ whatever: true }));
  app.post("/api/sessions", (_req, res) => res.status(400).json({ error: "bad name" }));
  await call(app, "GET", "/api/undeclared");
  await call(app, "POST", "/api/sessions");
  assert.deepEqual(problems, []);
});

// --- Against the real server ---
//
// server.js exports app and guards app.listen behind NODE_ENV !== "test", so
// importing it under NODE_ENV=test is safe and does not listen.

process.env.NODE_ENV = "test";
const { app: server } = await import("../server.js");
const serverTable = routeTable(server);

test("every route the contract publishes exists in the server's real route table", () => {
  assert.deepEqual(missingContractRoutes(contract, serverTable), []);
});

function readRoute(serverApp, path) {
  const layer = serverApp._router.stack.find((l) => l.route && l.route.path === path);
  assert.ok(layer, `the server has a ${path} route`);
  const handler = layer.route.stack[layer.route.stack.length - 1].handle;
  return new Promise((resolve) => {
    const res = {
      statusCode: 200,
      set() { return this; },
      setHeader() { return this; },
      status(code) { this.statusCode = code; return this; },
      json(payload) { resolve(payload); return this; },
    };
    handler({ method: "GET", params: {}, query: {}, headers: {}, path, originalUrl: path }, res);
  });
}

test("the document the server serves matches the fixture", async () => {
  const doc = await readRoute(server, "/api/contract");
  assert.deepEqual(doc, contract);
});

test("the served vocabulary is the server's own and the shared one", async () => {
  const doc = await readRoute(server, "/api/contract");
  assert.deepEqual(doc.statuses.vocabulary, [...STATUSES]);
  assert.deepEqual(doc.statuses.vocabulary, vocabulary.statuses);
});

test("the contract publishes the routes a client needs beyond listing sessions", () => {
  // A client that cannot find a route in the contract has to hard-code its
  // path, and a hard-coded path is how the two sides drift apart.
  for (const name of ["capture", "identity", "targets", "promptSession","promptPeerSession"]) {
    assert.ok(contract.routes[name], `the contract should publish the "${name}" route`);
    assert.ok(
      contract.shapes[contract.routes[name].shape],
      `the "${name}" route's shape should be declared`,
    );
  }
});

test("the contract publishes the promptSession route and its ack shape", () => {
  // A client prompts a session by name; the route is a deliberate surface,
  // published so the client never hard-codes the path.
  assert.deepEqual(contract.routes.promptSession, {
    method: "POST",
    path: "/api/sessions/{name}/send",
    shape: "sendAck",
  });

  // The success response the route serves keeps the shape it publishes:
  // exactly ok, name and paneId, nothing more.
  assert.deepEqual(
    checkShape("sendAck", { ok: true, name: "work", paneId: "%3" }, shapeCtx),
    [],
  );
  // An extra field is a problem, as everywhere else — publishing the API
  // means new fields are a deliberate act.
  const problems = checkShape(
    "sendAck",
    { ok: true, name: "work", paneId: "%3", surprise: 1 },
    shapeCtx,
  );
  assert.equal(problems.length, 1);
  assert.match(problems[0], /surprise/);
  // A wrong-typed declared field is a problem too.
  const mistyped = checkShape("sendAck", { ok: "yes", name: "work", paneId: "%3" }, shapeCtx);
  assert.equal(mistyped.length, 1);
  assert.match(mistyped[0], /ok/);
});

test("the contract publishes the promptPeerSession route, and its shape is sendAck", () => {
  // A client on machine A prompts an agent on machine B through AMA's peer
  // proxy. The route is published so the client never hard-codes the path,
  // and the success response is the same ack the local prompt route serves —
  // so it publishes the same shape. A peer running a different AMA version
  // that serves extra fields trips the shape guard loudly: publishing the
  // API means new fields are a deliberate act, on peers too.
  assert.deepEqual(contract.routes.promptPeerSession, {
    method: "POST",
    path: "/api/proxy/{peerHost}/sessions/{name}/send",
    shape: "sendAck",
  });
  assert.equal(contract.version, "10", "a change to the published routes is a version bump");

  // Declaring membership after creation: dragging a tile into or out of a
  // group is this server write (ADR 0017), and the ack carries the group the
  // server now declares.
  assert.deepEqual(contract.routes.setSessionGroup, {
    method: "POST",
    path: "/api/sessions/{name}/group",
    shape: "sessionGroup",
  });
  assert.deepEqual(
    checkShape("sessionGroup", { ok: true, name: "work", group: "Task Factory" }, shapeCtx),
    [],
  );
  assert.deepEqual(
    checkShape("sessionGroup", { ok: true, name: "work", group: null }, shapeCtx),
    [],
  );

  // Writing a session's task state: the owner's write (ADR 0018), acked with
  // the state the server now stores — null when it was cleared.
  assert.deepEqual(contract.routes.setSessionState, {
    method: "POST",
    path: "/api/sessions/{name}/state",
    shape: "sessionState",
  });
  assert.deepEqual(
    checkShape("sessionState", { ok: true, name: "work", state: "executing" }, shapeCtx),
    [],
  );
  assert.deepEqual(
    checkShape("sessionState", { ok: true, name: "work", state: null }, shapeCtx),
    [],
  );

  assert.deepEqual(
    checkShape("sendAck", { ok: true, name: "work", paneId: "%3" }, shapeCtx),
    [],
  );
  const problems = checkShape(
    "sendAck",
    { ok: true, name: "work", paneId: "%3", surprise: 1 },
    shapeCtx,
  );
  assert.equal(problems.length, 1);
  assert.match(problems[0], /surprise/);
});

test("the contract publishes the peer read routes", () => {
  // Reading the answer is the other half of prompting it: a peer agent's
  // reply has to come back through the mesh too, or a session the phone
  // can prompt but never hear is the same trap the session list once was.
  // The message proxy serves what the peer's own message route serves, and
  // the capture proxy what its capture route serves, so both publish the
  // shapes those routes already declare. A peer running a different AMA
  // version that serves extra fields trips the shape guard loudly, the
  // same way the prompt proxy does: publishing the API means new fields
  // are a deliberate act, on peers too.
  assert.deepEqual(contract.routes.readPeerMessages, {
    method: "GET",
    path: "/api/proxy/{peerHost}/sessions/{name}/message",
    shape: "agentMessageList",
  });
  assert.deepEqual(contract.routes.capturePeerSession, {
    method: "GET",
    path: "/api/proxy/{peerHost}/sessions/{target}/capture",
    shape: "capture",
  });
  assert.equal(contract.version, "10", "a change to the published routes is a version bump");

  assert.deepEqual(
    checkShape("agentMessageList", { messages: [{ id: 7, text: "done", at: 2, origin: null }] }, shapeCtx),
    [],
  );
  const messageProblems = checkShape(
    "agentMessageList",
    { messages: [{ id: 7, text: "done", at: 2, surprise: 1 }] },
    shapeCtx,
  );
  assert.equal(messageProblems.length, 1);
  assert.match(messageProblems[0], /surprise/);

  assert.deepEqual(
    checkShape("capture", { content: "❯ prompt", status: "idle", source: "screen" }, shapeCtx),
    [],
  );
});
