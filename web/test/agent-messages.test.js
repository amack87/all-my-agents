import { test } from "node:test";
import assert from "node:assert/strict";

import { createMessageStore } from "../agent-messages.js";

test("a filed message carries an increasing id, the text and a timestamp", () => {
  const store = createMessageStore();
  const first = store.file("slice", "working on it");
  const second = store.file("slice", "done");
  assert.ok(second > first, "the id increases within a session");
  const [one, two] = store.messages("slice");
  assert.deepEqual(one, { id: first, text: "working on it", at: one.at });
  assert.equal(typeof one.at, "number", "at is ms since the epoch");
  assert.deepEqual(two, { id: second, text: "done", at: two.at });
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
