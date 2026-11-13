// The shared status vocabulary, read from `contract/status-vocabulary.json` at
// the repo root. The macOS app's
// `Tests/AllMyAgentsTests/StatusVocabularyContractTests.swift` reads the same
// file.
//
// The server speaks five statuses. The macOS app used to know four of them:
// "ended" fell through to `.unknown` and rendered as "…" where this app
// rendered "Ended". The vocabulary now lives in one file of cases that both
// sides must satisfy, so the next change breaks a test on the side that was
// not updated.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  STATUSES,
  normalizeStatus,
  statusLabel,
  statusPriority,
} from "../public/session-status.js";

const here = dirname(fileURLToPath(import.meta.url));
const contractPath = join(here, "..", "..", "contract", "status-vocabulary.json");
const contract = JSON.parse(readFileSync(contractPath, "utf8"));

test("the status vocabulary contract is present", () => {
  assert.ok(Array.isArray(contract.statuses));
  assert.ok(contract.statuses.length > 0);
  assert.ok(Array.isArray(contract.wireCases));
  assert.ok(contract.wireCases.length > 0);
});

test("the status vocabulary contract maps identically to the macOS app", () => {
  for (const c of contract.wireCases) {
    assert.equal(
      normalizeStatus(c.wire),
      c.expected,
      `contract case "${c.name}"`,
    );
  }
});

test("the status vocabulary contract knows every status the server speaks", () => {
  assert.deepEqual([...STATUSES], contract.statuses);
});

test("the status vocabulary contract labels agree", () => {
  const labels = contract.labels?.web;
  assert.ok(labels, "the contract has no web labels");
  for (const status of STATUSES) {
    assert.equal(statusLabel(status), labels[status], `label for "${status}"`);
  }
});

test("the status vocabulary contract priority order agrees", () => {
  for (const status of STATUSES) {
    assert.equal(
      statusPriority(status),
      contract.priority[status],
      `priority for "${status}"`,
    );
  }
});
