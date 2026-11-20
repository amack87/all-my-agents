// The shared contract fixture, read from `contract/sidebar-groups.json` at the
// repo root. The macOS app's `Tests/AllMyAgentsTests/ContractTests.swift` reads
// the same file.
//
// This is the anti-drift mechanism: the groups-protected merge rule was
// hand-ported from this app into the macOS app, and the hand-port quietly
// disagreed with the original — a blank copy could erase a grouped one. The
// rule now lives in one file of cases that both sides must satisfy, so the
// next change breaks a test on the side that was not updated.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  pickWinner,
  orderHasGroups,
  isSafeGroupName,
} from "../public/sidebar-sync.js";
import { checkShape } from "../api-contract.js";
import { resolveOrder } from "../public/session-order.js";

const here = dirname(fileURLToPath(import.meta.url));
const contractPath = join(here, "..", "..", "contract", "sidebar-groups.json");
const contract = JSON.parse(readFileSync(contractPath, "utf8"));
const apiContract = JSON.parse(
  readFileSync(join(here, "..", "..", "contract", "api-contract.json"), "utf8"),
);
const sessionFieldsPath = join(here, "..", "..", "contract", "session-fields.json");
const sessionFields = JSON.parse(readFileSync(sessionFieldsPath, "utf8"));

// The membership merge: which tiles are in which group, in which order, when
// the sessions' server-declared groups meet the user's manual order. Both
// suites run their own ordering model over the same cases.
const membershipPath = join(here, "..", "..", "contract", "sidebar-membership.json");
const membership = JSON.parse(readFileSync(membershipPath, "utf8"));

const shapeCtx = { shapes: apiContract.shapes, vocabulary: apiContract.statuses.vocabulary };

test("the shared contract fixture is present", () => {
  assert.ok(Array.isArray(contract.winnerCases));
  assert.ok(contract.winnerCases.length > 0);
});

test("the shared contract resolves identically on the macOS app", () => {
  for (const c of contract.winnerCases) {
    assert.equal(
      pickWinner(c.local, c.remote),
      c.expected,
      `contract case "${c.name}"`,
    );
  }
});

test("the shared contract's group flags agree", () => {
  for (const c of contract.flagCases) {
    assert.equal(orderHasGroups(c.data), c.hasGroups, `contract case "${c.name}": hasGroups`);
  }
});

test("the shared contract's group names agree", () => {
  for (const name of contract.safeGroupNames) {
    assert.equal(isSafeGroupName(name), true, `"${name}" should be a safe group name`);
  }
  for (const name of contract.unsafeGroupNames) {
    assert.equal(isSafeGroupName(name), false, `"${name}" should be refused as a group name`);
  }
});

// The fields a session carries — its group and its directory — are published
// wherever a session is published. Each fixture case conforms to the named
// published shape, and the server resolves the fields as the case expects.
test("the shared session-fields contract conforms to the published shapes", () => {
  assert.ok(Array.isArray(sessionFields.cases));
  assert.ok(sessionFields.cases.length > 0);
  for (const c of sessionFields.cases) {
    const problems = checkShape(c.shape, c.session, shapeCtx);
    assert.deepEqual(problems, [], `contract case "${c.name}": shape problems`);
  }
});

test("the shared session-fields contract resolves identically on the macOS app", () => {
  for (const c of sessionFields.cases) {
    assert.equal(c.session.group, c.expected.group, `contract case "${c.name}": group`);
    assert.equal(c.session.dir, c.expected.dir, `contract case "${c.name}": dir`);
  }
});

test("the shared membership contract resolves identically on the macOS app", () => {
  assert.ok(Array.isArray(membership.cases));
  assert.ok(membership.cases.length > 0);
  for (const c of membership.cases) {
    const out = resolveOrder(c.data, c.sessions);
    const observed = {
      groups: out.groups.map((g) => ({
        name: g.name,
        serverDeclared: g.serverDeclared,
        members: g.sessions.map((s) => s.name),
      })),
      ungrouped: out.ungrouped.map((s) => s.name),
    };
    assert.deepEqual(observed, c.expected, `contract case "${c.name}"`);
  }
});
