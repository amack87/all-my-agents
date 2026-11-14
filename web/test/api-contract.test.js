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
