import { test } from "node:test";
import assert from "node:assert/strict";

import { createMessageStore } from "../agent-messages.js";

test("a filed message carries an increasing id, the text and a timestamp", () => {
  const store = createMessageStore();
  const first = store.file("slice", "working on it");
  const second = store.file("slice", "done");
  assert.ok(second > first, "the id increases within a session");
  const [one, two] = store.messages("slice");
  assert.deepEqual(one, { id: first, text: "working on it", at: one.at, origin: null });
  assert.equal(typeof one.at, "number", "at is ms since the epoch");
  assert.deepEqual(two, { id: second, text: "done", at: two.at, origin: null });
});

// Where a message came from is part of the record: a reply typed in the panel
// is James, text typed into a terminal is not, and a consumer reads the origin
// to tell them apart. A message filed without an origin has none — that is
// the honest value for text the server delivered on someone's behalf.
test("a filed message carries the origin it was filed with, or none", () => {
  const store = createMessageStore();
  store.file("slice", "yes, approved", "panel");
  store.file("slice", "the agent's own text");
  const [fromPanel, withoutOrigin] = store.messages("slice");
  assert.equal(fromPanel.origin, "panel");
  assert.equal(withoutOrigin.origin, null);
});

test("messages come back oldest first", () => {
  const store = createMessageStore();
  const ids = [store.file("slice", "one"), store.file("slice", "two"), store.file("slice", "three")];
  assert.deepEqual(store.messages("slice").map((m) => m.id), ids);
  assert.deepEqual(store.messages("slice").map((m) => m.text), ["one", "two", "three"]);
});

test("messages(name, since) returns only what came after the cursor", () => {
  const store = createMessageStore();
  const ids = [store.file("slice", "one"), store.file("slice", "two"), store.file("slice", "three")];
  assert.deepEqual(store.messages("slice", ids[0]).map((m) => m.text), ["two", "three"]);
  assert.deepEqual(store.messages("slice", ids[2]), []);
  assert.deepEqual(store.messages("slice", 0).map((m) => m.text), ["one", "two", "three"]);
});

test("a session that filed nothing answers with an empty list, not an error", () => {
  // That empty list is the fallback path for agents that do not report
  // their output; a missing message must never look like a fault.
  const store = createMessageStore();
  assert.deepEqual(store.messages("ghost"), []);
  assert.deepEqual(store.messages("ghost", 5), []);
});

test("sessions do not share ids or history", () => {
  const store = createMessageStore();
  const sliceId = store.file("slice", "for slice");
  const amaId = store.file("ama", "for ama");
  assert.deepEqual(store.messages("slice").map((m) => m.text), ["for slice"]);
  assert.deepEqual(store.messages("ama").map((m) => m.text), ["for ama"]);
  assert.equal(amaId, 1, "a fresh session starts its own ids");
  assert.ok(sliceId > 0);
});

test("latestId is the cursor a caller can resume from", () => {
  const store = createMessageStore();
  assert.equal(store.latestId("slice"), null);
  const a = store.file("slice", "one");
  const b = store.file("slice", "two");
  assert.equal(store.latestId("slice"), b);
  assert.ok(b > a);
  assert.equal(store.latestId("ama"), null);
});

test("clear drops the history and the cursor with it", () => {
  const store = createMessageStore();
  store.file("slice", "one");
  store.clear("slice");
  assert.deepEqual(store.messages("slice"), []);
  assert.equal(store.latestId("slice"), null);
});

// --- The routes that serve and file messages -------------------------------
//
// server.js guards app.listen behind NODE_ENV !== "test", so importing it is
// safe and does not listen. The pane lookup it uses is a seam the suite
// points at a stub, so these tests run without a live tmux pane.

process.env.NODE_ENV = "test";
const { app, agentMessages, surfaceTokens, paneResolution } = await import("../server.js");
const { checkShape } = await import("../api-contract.js");
const { readFileSync } = await import("node:fs");
const { dirname, join } = await import("node:path");
const { fileURLToPath } = await import("node:url");

const here = dirname(fileURLToPath(import.meta.url));
const contract = JSON.parse(
  readFileSync(join(here, "..", "..", "contract", "api-contract.json"), "utf8"),
);
const shapeCtx = { shapes: contract.shapes, vocabulary: contract.statuses.vocabulary };

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

test("the contract publishes the agent message route and the server serves it", () => {
  assert.deepEqual(
    contract.routes.agentMessage,
    { method: "GET", path: "/api/sessions/{name}/message", shape: "agentMessageList" },
  );
  assert.ok(contract.shapes.agentMessage, "the agentMessage shape is declared");
  assert.ok(contract.shapes.agentMessageList, "the agentMessageList shape is declared");
});

test("the message route answers with the filed messages, oldest first", async () => {
  paneResolution.paneFor = livePane;
  try {
    const ids = [
      agentMessages.file("route-slice", "first reply"),
      agentMessages.file("route-slice", "second reply"),
    ];
    const { statusCode, payload } = await call("GET", "/api/sessions/route-slice/message");
    assert.equal(statusCode, 200);
    assert.deepEqual(
      payload.messages.map((m) => ({ id: m.id, text: m.text })),
      [{ id: ids[0], text: "first reply" }, { id: ids[1], text: "second reply" }],
    );
    assert.deepEqual(checkShape("agentMessageList", payload, shapeCtx), []);
  } finally {
    agentMessages.clear("route-slice");
    paneResolution.paneFor = realPaneFor;
  }
});

test("the message route honours the since cursor", async () => {
  paneResolution.paneFor = livePane;
  try {
    const ids = [
      agentMessages.file("route-slice", "first reply"),
      agentMessages.file("route-slice", "second reply"),
    ];
    const { payload } = await call("GET", `/api/sessions/route-slice/message?since=${ids[0]}`);
    assert.deepEqual(payload.messages.map((m) => m.id), [ids[1]]);
  } finally {
    agentMessages.clear("route-slice");
    paneResolution.paneFor = realPaneFor;
  }
});

test("an unparseable since cursor means everything", async () => {
  paneResolution.paneFor = livePane;
  try {
    agentMessages.file("route-slice", "first reply");
    const { payload } = await call("GET", "/api/sessions/route-slice/message?since=nonsense");
    assert.equal(payload.messages.length, 1);
  } finally {
    agentMessages.clear("route-slice");
    paneResolution.paneFor = realPaneFor;
  }
});

test("a session that resolves but reported nothing is an empty list", async () => {
  paneResolution.paneFor = livePane;
  try {
    const { statusCode, payload } = await call("GET", "/api/sessions/never-filed/message");
    assert.equal(statusCode, 200);
    assert.deepEqual(payload, { messages: [] });
  } finally {
    paneResolution.paneFor = realPaneFor;
  }
});

test("a session name that does not resolve is a 404, not a failure", async () => {
  paneResolution.paneFor = async () => null;
  try {
    const { statusCode, payload } = await call("GET", "/api/sessions/ghost-session/message");
    assert.equal(statusCode, 404);
    assert.ok("error" in payload);
  } finally {
    paneResolution.paneFor = realPaneFor;
  }
});

test("an event that carries a message files it against the resolved session", async () => {
  surfaceTokens.set("tok-agent-message", "event-slice");
  paneResolution.paneFor = livePane;
  try {
    const before = agentMessages.latestId("event-slice");
    const { statusCode, payload } = await call("POST", "/api/events", {
      event: "stop",
      surfaceToken: "tok-agent-message",
      message: "the reply",
    });
    assert.equal(statusCode, 200);
    assert.equal(typeof payload.messageId, "number");
    assert.ok(payload.messageId > (before ?? 0), "the ack carries the id of the filed message");
    const stored = agentMessages.messages("event-slice", before ?? 0);
    assert.deepEqual(stored.map((m) => m.text), ["the reply"]);
  } finally {
    surfaceTokens.delete("tok-agent-message");
    agentMessages.clear("event-slice");
    paneResolution.paneFor = realPaneFor;
  }
});

test("an event without a message acks a null id and files nothing", async () => {
  surfaceTokens.set("tok-agent-message", "event-slice");
  paneResolution.paneFor = livePane;
  try {
    const { payload } = await call("POST", "/api/events", {
      event: "stop",
      surfaceToken: "tok-agent-message",
    });
    assert.equal(payload.messageId, null);
    assert.deepEqual(agentMessages.messages("event-slice"), []);
  } finally {
    surfaceTokens.delete("tok-agent-message");
    paneResolution.paneFor = realPaneFor;
  }
});

test("an unmatched event files nothing", async () => {
  surfaceTokens.set("tok-agent-message", "event-slice");
  paneResolution.paneFor = livePane;
  try {
    const { statusCode, payload } = await call("POST", "/api/events", {
      event: "stop",
      surfaceToken: "tok-nobody-minted",
      message: "a message with nowhere to go",
    });
    assert.equal(statusCode, 422);
    assert.deepEqual(agentMessages.messages("event-slice"), []);
  } finally {
    surfaceTokens.delete("tok-agent-message");
    paneResolution.paneFor = realPaneFor;
  }
});
