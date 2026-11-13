import { test } from "node:test";
import assert from "node:assert/strict";

import { createStatusFeed, snapshotSignature } from "../status-feed.js";

function makeSnapshot(status, extra = {}) {
  return {
    sessions: [
      { name: "alpha", paneId: "%1", status, agent: "Claude Code", lastActivity: 100 },
    ],
    peerStatus: {},
    ...extra,
  };
}

test("a snapshot's signature changes when a session's status changes", () => {
  const before = makeSnapshot("working");
  const after = makeSnapshot("needsInput");
  assert.notEqual(snapshotSignature(before), snapshotSignature(after));
});

test("a snapshot's signature is stable for identical content", () => {
  assert.equal(
    snapshotSignature(makeSnapshot("working")),
    snapshotSignature(makeSnapshot("working")),
  );
});

test("a snapshot's signature changes when a session appears", () => {
  const before = makeSnapshot("working");
  const after = makeSnapshot("working");
  after.sessions.push({ name: "beta", paneId: "%2", status: "idle", agent: "shell", lastActivity: 50 });
  assert.notEqual(snapshotSignature(before), snapshotSignature(after));
});

test("a snapshot's signature changes when a peer's health changes", () => {
  const before = makeSnapshot("working");
  const after = makeSnapshot("working", { peerStatus: { other: "ok" } });
  assert.notEqual(snapshotSignature(before), snapshotSignature(after));
});

test("the feed sends a subscriber the current snapshot when it joins", async () => {
  const feed = createStatusFeed({ discover: async () => makeSnapshot("working") });
  const received = [];
  await feed.subscribe({ send: (msg) => received.push(msg) });
  assert.equal(received.length, 1);
  assert.equal(received[0].type, "sessions");
  assert.equal(received[0].sessions[0].name, "alpha");
});

test("a subscriber that joins later still gets the current snapshot", async () => {
  const snapshot = makeSnapshot("working");
  const feed = createStatusFeed({ discover: async () => snapshot });

  const first = [];
  await feed.subscribe({ send: (msg) => first.push(msg) });
  assert.equal(first.length, 1);

  // The second subscriber arrives when the snapshot has not changed since the
  // first one did, so nothing is pushed. It must still be told what the
  // current state is, or it waits in silence until the next change.
  const late = [];
  await feed.subscribe({ send: (msg) => late.push(msg) });
  assert.equal(late.length, 1, "a late subscriber is handed the current snapshot");
  assert.equal(late[0].type, "sessions");
  assert.deepEqual(late[0].sessions, snapshot.sessions);
});

test("the feed does not run its ticker until somebody subscribes", async () => {
  let ticks = 0;
  const feed = createStatusFeed({
    discover: async () => makeSnapshot("working"),
    onTick: () => { ticks += 1; },
  });
  assert.equal(feed.isRunning, false);
  assert.equal(feed.subscriberCount, 0);
  assert.equal(ticks, 0);
});

test("the feed stops its ticker when the last subscriber leaves", async () => {
  const feed = createStatusFeed({ discover: async () => makeSnapshot("working") });
  const subscriber = { send: () => {} };
  await feed.subscribe(subscriber);
  assert.equal(feed.isRunning, true);
  feed.unsubscribe(subscriber);
  assert.equal(feed.isRunning, false);
  assert.equal(feed.subscriberCount, 0);
});

test("the feed keeps running while any subscriber remains", async () => {
  const feed = createStatusFeed({ discover: async () => makeSnapshot("working") });
  const first = { send: () => {} };
  const second = { send: () => {} };
  await feed.subscribe(first);
  await feed.subscribe(second);
  feed.unsubscribe(first);
  assert.equal(feed.isRunning, true);
  assert.equal(feed.subscriberCount, 1);
});

test("a refresh pushes a full snapshot to every subscriber", async () => {
  let status = "working";
  const feed = createStatusFeed({ discover: async () => makeSnapshot(status) });
  const first = [];
  const second = [];
  await feed.subscribe({ send: (msg) => first.push(msg) });
  await feed.subscribe({ send: (msg) => second.push(msg) });
  first.length = 0;
  second.length = 0;

  status = "needsInput";
  await feed.refreshNow();

  assert.equal(first.length, 1);
  assert.equal(second.length, 1);
  assert.equal(first[0].sessions[0].status, "needsInput");
  assert.equal(second[0].sessions[0].status, "needsInput");
});

test("a refresh that changes nothing pushes nothing", async () => {
  const feed = createStatusFeed({ discover: async () => makeSnapshot("working") });
  const received = [];
  await feed.subscribe({ send: (msg) => received.push(msg) });
  received.length = 0;

  await feed.refreshNow();
  await feed.refreshNow();

  assert.equal(received.length, 0);
});

test("overlapping refreshes share one discovery pass", async () => {
  let discoveries = 0;
  const feed = createStatusFeed({
    discover: async () => {
      discoveries += 1;
      await new Promise((resolve) => setTimeout(resolve, 5));
      return makeSnapshot("working");
    },
  });

  await Promise.all([feed.refreshNow(), feed.refreshNow(), feed.refreshNow()]);
  assert.equal(discoveries, 1);
});

test("a failed discovery leaves the previous snapshot in place", async () => {
  let shouldFail = false;
  const feed = createStatusFeed({
    discover: async () => {
      if (shouldFail) throw new Error("boom");
      return makeSnapshot("working");
    },
  });
  await feed.refreshNow();
  shouldFail = true;
  await feed.refreshNow();
  assert.equal(feed.current.sessions[0].status, "working");
});

test("a refresh that follows a failure stays quiet when nothing changed", async () => {
  let shouldFail = false;
  const feed = createStatusFeed({
    discover: async () => {
      if (shouldFail) throw new Error("boom");
      return makeSnapshot("working");
    },
  });
  const received = [];
  await feed.subscribe({ send: (msg) => received.push(msg) });
  received.length = 0;

  shouldFail = true;
  await feed.refreshNow();
  assert.equal(received.length, 0);

  // The client's view is still accurate — the recovered snapshot is the same
  // one it already has, so there is nothing to push.
  shouldFail = false;
  await feed.refreshNow();
  assert.equal(received.length, 0);
});

test("a refresh after a failure pushes a snapshot that really changed", async () => {
  let shouldFail = false;
  let status = "working";
  const feed = createStatusFeed({
    discover: async () => {
      if (shouldFail) throw new Error("boom");
      return makeSnapshot(status);
    },
  });
  const received = [];
  await feed.subscribe({ send: (msg) => received.push(msg) });
  received.length = 0;

  shouldFail = true;
  await feed.refreshNow();
  status = "needsInput";
  shouldFail = false;
  await feed.refreshNow();

  assert.equal(received.length, 1);
  assert.equal(received[0].sessions[0].status, "needsInput");
});
