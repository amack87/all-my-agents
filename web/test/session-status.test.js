import test from "node:test";
import assert from "node:assert/strict";

import {
  STATUSES,
  normalizeStatus,
  statusLabel,
  statusPriority,
  sortSessionsByStatus,
} from "../public/session-status.js";

test("the vocabulary is exactly the five statuses the server speaks", () => {
  assert.deepEqual([...STATUSES], [
    "needsInput",
    "working",
    "idle",
    "ended",
    "unknown",
  ]);
});

test("a known status survives normalization", () => {
  for (const status of STATUSES) {
    assert.equal(normalizeStatus(status), status);
  }
});

test("an unknown status becomes unknown", () => {
  assert.equal(normalizeStatus("banana"), "unknown");
  assert.equal(normalizeStatus(""), "unknown");
  assert.equal(normalizeStatus(null), "unknown");
  assert.equal(normalizeStatus(undefined), "unknown");
  assert.equal(normalizeStatus(42), "unknown");
});

test("every status has a label", () => {
  for (const status of STATUSES) {
    assert.equal(typeof statusLabel(status), "string");
    assert.ok(statusLabel(status).length > 0);
  }
});

test("an unknown status has a label too", () => {
  assert.equal(statusLabel("banana"), "...");
});

test("statuses sort by attention, then by how recently they were active", () => {
  assert.equal(statusPriority("needsInput"), 0);
  assert.equal(statusPriority("working"), 1);
  assert.equal(statusPriority("idle"), 2);
  assert.equal(statusPriority("ended"), 3);
  assert.equal(statusPriority("unknown"), 4);
});

test("sessions sort by status priority, then most recent activity first", () => {
  const sessions = [
    { name: "idle-old", status: "idle", lastActivity: 100 },
    { name: "unknown", status: "unknown", lastActivity: 999 },
    { name: "working", status: "working", lastActivity: 50 },
    { name: "needs-input", status: "needsInput", lastActivity: 10 },
    { name: "idle-new", status: "idle", lastActivity: 500 },
  ];
  assert.deepEqual(
    sortSessionsByStatus(sessions).map((s) => s.name),
    ["needs-input", "working", "idle-new", "idle-old", "unknown"],
  );
});

test("sorting does not mutate the sessions it is given", () => {
  const sessions = [
    { name: "idle", status: "idle", lastActivity: 100 },
    { name: "working", status: "working", lastActivity: 50 },
  ];
  const copy = [...sessions];
  sortSessionsByStatus(sessions);
  assert.deepEqual(sessions, copy);
});
