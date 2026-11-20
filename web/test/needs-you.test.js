// "Needs you" — what a person sees: which sessions are waiting on them, in
// what order, and what is not on the list. The list is a view; the test
// asserts that nothing about a session is changed by being on it.

import { test } from "node:test";
import assert from "node:assert/strict";

import { needsYou } from "../public/needs-you.js";

function session(overrides = {}) {
  return {
    name: "slice",
    machineHost: "local",
    status: "idle",
    group: null,
    lastActivity: 1000,
    ...overrides,
  };
}

test("needs you lists exactly the grouped sessions whose status is needsInput", () => {
  const waiting = session({ name: "waiting", group: "Task Factory", status: "needsInput", lastActivity: 3000 });
  const sessions = [
    session({ name: "working", group: "Task Factory", status: "working" }),
    waiting,
    session({ name: "ungrouped-waiting", status: "needsInput", lastActivity: 1000 }),
    session({ name: "other-group-idle", group: "Side quests", status: "needsInput", lastActivity: 2000 }),
    session({ name: "ended", group: "Task Factory", status: "ended" }),
  ];
  const listed = needsYou(sessions);
  assert.deepEqual(
    listed.map((s) => s.name),
    ["other-group-idle", "waiting"],
    "only grouped sessions waiting on input are listed, oldest wait first",
  );
  assert.deepEqual(listed[1], waiting, "the listed session is the session itself, unchanged");
});

test("needs you is oldest wait first", () => {
  const sessions = [
    session({ name: "fresh", group: "Task Factory", status: "needsInput", lastActivity: 9000 }),
    session({ name: "stale", group: "Task Factory", status: "needsInput", lastActivity: 2000 }),
    session({ name: "older", group: "Task Factory", status: "needsInput", lastActivity: 1000 }),
  ];
  assert.deepEqual(
    needsYou(sessions).map((s) => s.name),
    ["older", "stale", "fresh"],
    "the session that has waited longest is first",
  );
});

test("a session that belongs to no group is never waiting on the list", () => {
  // The panel works for an ungrouped session; "needs you" is a list of the
  // members of a group. An ungrouped session's wait is real but out of scope.
  const sessions = [
    session({ name: "loner", status: "needsInput", lastActivity: 1000 }),
    session({ name: "empty-group-string", group: "", status: "needsInput", lastActivity: 2000 }),
  ];
  assert.deepEqual(needsYou(sessions), []);
});

test("needs you is empty when nothing waits", () => {
  assert.deepEqual(needsYou([]), []);
  assert.deepEqual(
    needsYou([session({ group: "Task Factory", status: "idle" })]),
    [],
  );
});

test("a wait whose start is unknown sorts first", () => {
  // lastActivity 0 means the session never reported activity; nothing is
  // older than a wait nobody can time, so it leads the backlog.
  const sessions = [
    session({ name: "timed", group: "Task Factory", status: "needsInput", lastActivity: 5000 }),
    session({ name: "untimed", group: "Task Factory", status: "needsInput", lastActivity: 0 }),
  ];
  assert.deepEqual(
    needsYou(sessions).map((s) => s.name),
    ["untimed", "timed"],
  );
});
