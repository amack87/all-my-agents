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
  orderClearedGroups,
  isSafeGroupName,
} from "../public/sidebar-sync.js";

const here = dirname(fileURLToPath(import.meta.url));
const contractPath = join(here, "..", "..", "contract", "sidebar-groups.json");
const contract = JSON.parse(readFileSync(contractPath, "utf8"));

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
    assert.equal(
      orderClearedGroups(c.data),
      c.clearedGroups,
      `contract case "${c.name}": clearedGroups`,
    );
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
