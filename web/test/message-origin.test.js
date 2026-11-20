// The shared message-origin fixture, read from `contract/message-origin.json`
// at the repo root. The macOS app's MessageOriginContractTests.swift reads the
// same file.
//
// This is the anti-drift rule applied to the chat panel's record: where a
// message came from is a fact both apps must agree on, so the cases live in
// one fixture and each suite asserts it resolves identically — the message
// conforms to the published agentMessage shape, and "from the panel" resolves
// to the same answer on both sides.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { checkShape } from "../api-contract.js";
import { isPanelMessage, PANEL_ORIGIN, AGENT_ORIGIN } from "../public/message-origin.js";

const here = dirname(fileURLToPath(import.meta.url));
const contract = JSON.parse(
  readFileSync(join(here, "..", "..", "contract", "message-origin.json"), "utf8"),
);
const apiContract = JSON.parse(
  readFileSync(join(here, "..", "..", "contract", "api-contract.json"), "utf8"),
);
const shapeCtx = { shapes: apiContract.shapes, vocabulary: apiContract.statuses.vocabulary };

test("the shared message-origin fixture is present", () => {
  assert.ok(Array.isArray(contract.cases));
  assert.ok(contract.cases.length > 0);
  assert.equal(typeof contract.panelOrigin, "string");
});

test("every fixture message conforms to the published agentMessage shape", () => {
  for (const c of contract.cases) {
    const problems = checkShape("agentMessage", c.message, shapeCtx);
    assert.deepEqual(problems, [], `contract case "${c.name}": shape problems`);
  }
});

test("a fixture message is from the panel exactly when the fixture says so", () => {
  for (const c of contract.cases) {
    assert.equal(isPanelMessage(c.message), c.fromPanel, `contract case "${c.name}"`);
  }
});

test("the origins the server files are the fixture's origins", () => {
  // The server files "agent" for the adapter's report and "panel" for a panel
  // reply (through the send body). If the words drift from the fixture, the
  // two suites would agree on a rule neither side actually speaks.
  assert.equal(PANEL_ORIGIN, contract.panelOrigin);
  assert.equal(AGENT_ORIGIN, contract.agentOrigin);
});
