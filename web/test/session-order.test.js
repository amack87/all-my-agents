import { test } from "node:test";
import assert from "node:assert/strict";

import {
  createEmptyOrder,
  moveSession,
  moveGroup,
  resolveOrder,
} from "../public/session-order.js";

const key = (machineHost, name) => `${machineHost || "local"}::${name}`;

function sess(name, machineHost = "local") {
  return { key: key(machineHost, name), name };
}

// A session that declares the group it belongs to (ADR 0017: membership is
// server-declared — the session carries its group).
function declared(name, group, machineHost = "local") {
  return { key: key(machineHost, name), name, group };
}

const data = (over = {}) => ({
  groups: {},
  collapsed: {},
  order: [],
  ungroupedOrder: [],
  serverGroups: [],
  ...over,
});

test("createEmptyOrder returns the canonical empty structure", () => {
  assert.deepEqual(createEmptyOrder(), {
    groups: {},
    collapsed: {},
    order: [],
    ungroupedOrder: [],
    serverGroups: [],
  });
});

test("moveSession reorders within the ungrouped region", () => {
  const input = data({ ungroupedOrder: ["a", "b", "c", "d"] });
  const out = moveSession(input, "a", null, 2);
  assert.deepEqual(out.ungroupedOrder, ["b", "c", "a", "d"]);
});

test("moveSession moves a key from a group into the ungrouped region at an index", () => {
  const input = data({
    groups: { G: ["x", "y"] },
    order: ["G"],
    ungroupedOrder: ["a", "b"],
  });
  const out = moveSession(input, "x", null, 1);
  assert.deepEqual(out.groups.G, ["y"]);
  assert.deepEqual(out.ungroupedOrder, ["a", "x", "b"]);
});

test("moveSession moves a key from the ungrouped region into a group at an index", () => {
  const input = data({
    groups: { G: ["x", "y"] },
    order: ["G"],
    ungroupedOrder: ["a", "b"],
  });
  const out = moveSession(input, "b", "G", 1);
  assert.deepEqual(out.groups.G, ["x", "b", "y"]);
  assert.deepEqual(out.ungroupedOrder, ["a"]);
});

test("moveSession moves a key between groups", () => {
  const input = data({
    groups: { G: ["x", "y"], H: ["p", "q"] },
    order: ["G", "H"],
  });
  const out = moveSession(input, "x", "H", 2);
  assert.deepEqual(out.groups.G, ["y"]);
  assert.deepEqual(out.groups.H, ["p", "q", "x"]);
});

test("moveSession clamps an out-of-range index", () => {
  const input = data({ groups: { G: ["x"] }, order: ["G"], ungroupedOrder: ["a"] });
  assert.deepEqual(moveSession(input, "a", "G", 99).groups.G, ["x", "a"]);
  assert.deepEqual(moveSession(input, "a", null, -5).ungroupedOrder, ["a"]);
});

test("moveSession does not mutate its input", () => {
  const input = data({ ungroupedOrder: ["a", "b"] });
  const snapshot = JSON.parse(JSON.stringify(input));
  moveSession(input, "a", null, 1);
  assert.deepEqual(input, snapshot);
});

test("moveGroup reorders the group order array", () => {
  const input = data({ groups: { A: [], B: [], C: [] }, order: ["A", "B", "C"] });
  const out = moveGroup(input, "C", 0);
  assert.deepEqual(out.order, ["C", "A", "B"]);
});

test("moveGroup clamps an out-of-range index", () => {
  const input = data({ groups: { A: {}, B: {} }, order: ["A", "B"] });
  assert.deepEqual(moveGroup(input, "A", 99).order, ["B", "A"]);
});

test("moveGroup inserts at the post-removal index (callers pre-shift rendered indices)", () => {
  // Dragging A below C renders at index 3 in [A,B,C,D]; the caller shifts
  // 3 -> 2 because A is removed first, landing A between C and D.
  const input = data({ groups: { A: [], B: [], C: [], D: [] }, order: ["A", "B", "C", "D"] });
  assert.deepEqual(moveGroup(input, "A", 2).order, ["B", "C", "A", "D"]);
  assert.deepEqual(moveGroup(input, "D", 1).order, ["A", "D", "B", "C"]);
});

test("resolveOrder seeds unseen keys at the top of the ungrouped region", () => {
  const input = data({ ungroupedOrder: ["local::old"] });
  const out = resolveOrder(input, [sess("new1"), sess("old")], (s) => s.key);
  assert.deepEqual(out.data.ungroupedOrder, ["local::new1", "local::old"]);
  assert.deepEqual(out.ungrouped.map((s) => s.name), ["new1", "old"]);
  assert.equal(out.changed, true);
});

test("resolveOrder keeps absent keys so returning sessions keep their slot", () => {
  const input = data({ ungroupedOrder: [key("local", "a"), key("local", "gone"), key("local", "b")] });
  const out = resolveOrder(input, [sess("a"), sess("b")], (s) => s.key);
  assert.deepEqual(out.data.ungroupedOrder, [
    key("local", "a"),
    key("local", "gone"),
    key("local", "b"),
  ]);
  assert.deepEqual(out.ungrouped.map((s) => s.name), ["a", "b"]);
  // When "gone" comes back it lands in its old slot.
  const back = resolveOrder(out.data, [sess("a"), sess("gone"), sess("b")], (s) => s.key);
  assert.deepEqual(back.ungrouped.map((s) => s.name), ["a", "gone", "b"]);
});

test("resolveOrder rewrites a stored key when the machine host changes", () => {
  const input = data({ groups: { G: [key("oldhost", "web")] }, order: ["G"] });
  const out = resolveOrder(input, [declared("web", "G", "newhost")], (s) => s.key);
  assert.deepEqual(out.groups[0].sessions.map((s) => s.name), ["web"]);
  assert.deepEqual(out.data.groups.G, [key("newhost", "web")]);
});

test("resolveOrder returns groups in stored order including empty ones", () => {
  const input = data({
    groups: { G: ["a"], Empty: [] },
    order: ["G", "Empty"],
    ungroupedOrder: [],
  });
  const out = resolveOrder(input, [sess("a")], (s) => s.key);
  assert.deepEqual(out.groups.map((g) => g.name), ["G", "Empty"]);
  assert.deepEqual(out.groups[1].sessions, []);
});

test("resolveOrder appends group names missing from the order array", () => {
  const input = data({ groups: { G: [], Lost: [] }, order: ["G"] });
  const out = resolveOrder(input, [], (s) => s.key);
  assert.deepEqual(out.groups.map((g) => g.name), ["G", "Lost"]);
});

test("resolveOrder seeds a brand-new session at the top of ungrouped", () => {
  const input = data({ groups: { G: ["g1"] }, order: ["G"], ungroupedOrder: ["u1"] });
  const out = resolveOrder(input, [declared("g1", "G"), sess("u1"), sess("fresh")], (s) => s.key);
  assert.deepEqual(out.groups[0].sessions.map((s) => s.name), ["g1"]);
  assert.deepEqual(out.ungrouped.map((s) => s.name), ["fresh", "u1"]);
});

test("resolveOrder does not mutate its input", () => {
  const input = data({ groups: { G: ["a"] }, order: ["G"], ungroupedOrder: ["b"] });
  const snapshot = JSON.parse(JSON.stringify(input));
  resolveOrder(input, [sess("a"), sess("b"), sess("c")], (s) => s.key);
  assert.deepEqual(input, snapshot);
});

test("a group name that collides with Object.prototype is never created", () => {
  const moved = moveSession(data(), key("local", "slice"), "__proto__", 0);
  assert.deepEqual(Object.keys(moved.groups), []);
  assert.deepEqual(moved.ungroupedOrder, [key("local", "slice")]);
  assert.equal(Object.getPrototypeOf(moved.groups), Object.prototype);
});

test("moving a session into an unsafe group lands it ungrouped", () => {
  const moved = moveSession(data(), key("local", "slice"), "constructor", 0);
  assert.deepEqual(Object.keys(moved.groups), []);
  assert.deepEqual(moved.ungroupedOrder, [key("local", "slice")]);
});

test("moving an unsafe group is a no-op", () => {
  const before = data({ groups: { Work: [] }, order: ["Work"] });
  const after = moveGroup(before, "__proto__", 0);
  assert.deepEqual(after.order, ["Work"]);
  assert.deepEqual(Object.keys(after.groups), ["Work"]);
});

// --- Membership is server-declared (ADR 0017) ---
//
// The store's groups map is the order inside a group, not the membership: a
// session renders where the server says it belongs, merged with the manual
// order. A group the store has never seen is adopted for rendering, not
// claimed — James claims a group by acting on it.

test("a session created in a group appears under that group with no stored membership", () => {
  const out = resolveOrder(createEmptyOrder(), [declared("alpha", "Task Factory")]);
  assert.deepEqual(
    out.groups.map((g) => ({ name: g.name, serverDeclared: g.serverDeclared, members: g.sessions.map((s) => s.name) })),
    [{ name: "Task Factory", serverDeclared: true, members: ["alpha"] }],
  );
  assert.deepEqual(out.ungrouped, []);
  // Adoption is recorded so the next resolve is stable, but the group is not
  // claimed: James's own groups live in `order`.
  assert.deepEqual(out.data.serverGroups, ["Task Factory"]);
  assert.deepEqual(out.data.order, []);
  assert.equal(out.changed, true);
});

test("a new member is appended after the existing members, leaving their order alone", () => {
  // The previous resolve stored the group's member order; a member that
  // arrives later appends at the end instead of reshuffling the rest.
  const input = data({
    groups: { "Task Factory": [key("local", "one")] },
    serverGroups: ["Task Factory"],
  });
  const out = resolveOrder(input, [declared("two", "Task Factory"), declared("one", "Task Factory")], (s) => s.key);
  assert.deepEqual(out.groups[0].sessions.map((s) => s.name), ["one", "two"]);
  assert.deepEqual(out.data.groups["Task Factory"], [key("local", "one"), key("local", "two")]);
});

test("a session that declares another group moves out of the group it was stored under", () => {
  const input = data({
    groups: { A: [key("local", "x")], B: [] },
    order: ["A", "B"],
  });
  const out = resolveOrder(input, [declared("x", "B")]);
  assert.deepEqual(out.groups[0].sessions, [], "A keeps its header but loses the tile");
  assert.deepEqual(out.groups[1].sessions.map((s) => s.name), ["x"]);
  assert.deepEqual(out.data.groups.A, [], "the stale ordering entry is cleaned up");
});

test("a live session with no declared group is not held by a stored group", () => {
  // Membership used to be client-owned; the server never declared it, so a
  // session stored in a group but declaring none belongs in the ungrouped
  // region — it must not become invisible.
  const input = data({ groups: { A: [key("local", "x")] }, order: ["A"] });
  const out = resolveOrder(input, [sess("x")]);
  assert.deepEqual(out.groups[0].sessions, []);
  assert.deepEqual(out.ungrouped.map((s) => s.name), ["x"]);
  assert.deepEqual(out.data.groups.A, []);
  assert.deepEqual(out.data.ungroupedOrder, [key("local", "x")]);
});

test("a server-declared group James claims by acting on is no longer server-declared", () => {
  const claimed = moveSession(createEmptyOrder(), key("local", "alpha"), "Task Factory", 0);
  assert.deepEqual(claimed.order, ["Task Factory"]);
  assert.deepEqual(claimed.serverGroups, [], "claiming removes the adoption record");
  const out = resolveOrder(claimed, [declared("alpha", "Task Factory")]);
  assert.equal(out.groups[0].serverDeclared, false);
});

test("moveGroup claims a server-declared group too", () => {
  const input = data({ groups: { "Task Factory": [] }, serverGroups: ["Task Factory"] });
  const out = moveGroup(input, "Task Factory", 0);
  assert.deepEqual(out.order, ["Task Factory"]);
  assert.deepEqual(out.serverGroups, []);
});

test("a server-declared group whose members are all gone is dropped, without residue", () => {
  const seeded = resolveOrder(createEmptyOrder(), [declared("alpha", "Task Factory")]);
  const out = resolveOrder(seeded.data, []);
  assert.deepEqual(out.data.serverGroups, [], "the adoption record goes with the members");
  assert.deepEqual(Object.keys(out.data.groups), [], "no ordering residue is left behind");
  assert.deepEqual(out.groups, [], "the group is not rendered without members");
});

test("a user group survives as an empty header even when no session declares it", () => {
  const input = data({ groups: { G: [], Lost: [] }, order: ["G"] });
  const out = resolveOrder(input, [], (s) => s.key);
  assert.deepEqual(out.groups.map((g) => g.name), ["G", "Lost"]);
});

test("an unsafe declared group name is treated as no group", () => {
  const out = resolveOrder(createEmptyOrder(), [{ key: key("local", "x"), name: "x", group: "__proto__" }]);
  assert.deepEqual(out.groups, []);
  assert.deepEqual(out.ungrouped.map((s) => s.name), ["x"]);
});

test("resolution does not mutate its input, including serverGroups", () => {
  const input = { ...createEmptyOrder(), groups: { A: [key("local", "x")] }, order: ["A"] };
  const snapshot = JSON.parse(JSON.stringify(input));
  resolveOrder(input, [declared("x", "B")]);
  assert.deepEqual(input, snapshot);
});
