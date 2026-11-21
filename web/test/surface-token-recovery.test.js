// Recovering a surface token the server forgot.
//
// The server's token map lives in memory; a pane keeps its token in tmux. A
// server restart forgets every token, so a live agent reports with a token the
// server has never heard of. The server re-learns it from the pane rather than
// minting a second one the running agent cannot know about (ADR 0019).
//
// The rules live in web/surface-token-recovery.js and are pure; the server
// only performs the calls. Here they are asserted directly, and then through
// the real endpoint with tmux stubbed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  SURFACE_TOKEN_ENV,
  parseSurfaceToken,
  planAdoptions,
  recoveryAction,
  shouldSweep,
} from "../surface-token-recovery.js";

// The registry a session id is resolved against is read from disk at boot, so
// the test points the log directory at a temporary one and writes a registry
// there before the server is imported.
const logDir = mkdtempSync(join(tmpdir(), "ama-token-"));
process.env.ALL_MY_AGENTS_LOG_DIR = logDir;
process.env.ALL_MY_AGENTS_REGISTRY_POLL_MS = "3600000";
// The sweep and the mint are rate limited so a spammy reporter cannot turn
// them into a tmux hammer. The test needs them not to be.
process.env.ALL_MY_AGENTS_SURFACE_TOKEN_MIN_INTERVAL_MS = "0";
writeFileSync(
  join(logDir, "active-sessions.json"),
  JSON.stringify({
    version: 2,
    updatedAt: Date.now(),
    sessions: [
      { sessionId: "ses_mine", tmux: "mine-slice" },
      { sessionId: "ses_foreign", tmux: "foreign-slice" },
    ],
  }),
);

process.env.NODE_ENV = "test";
const { app, surfaceTokens, paneResolution, tmuxOps } = await import("../server.js");

// A fake tmux: the sessions that exist and the environment each one holds.
const tmuxEnv = new Map(); // session name → "AMA_SURFACE_TOKEN=<token>"
const tmuxSessions = new Set();
const published = []; // tokens the server published into a pane

function stubTmux() {
  tmuxOps.run = async (...args) => {
    const [command] = args;
    if (command === "list-sessions") return [...tmuxSessions].join("\n");
    if (command === "show-environment") {
      const name = args[2];
      const held = tmuxEnv.get(name);
      if (!held) throw new Error("unknown variable: AMA_SURFACE_TOKEN");
      return held;
    }
    if (command === "set-environment") {
      const name = args[2];
      const token = args[4];
      tmuxEnv.set(name, `${SURFACE_TOKEN_ENV}=${token}`);
      published.push({ name, token });
      return "";
    }
    return "";
  };
}

const realPaneFor = paneResolution.paneFor;
const livePane = async () => "%9";

function call(method, url, body) {
  return new Promise((resolve) => {
    const res = {
      statusCode: 200,
      set() { return this; },
      setHeader() { return this; },
      status(code) { this.statusCode = code; return this; },
      json(payload) { resolve({ statusCode: this.statusCode, payload }); return this; },
    };
    app({ method, url, headers: {}, body }, res);
  });
}

async function postEvent(body) {
  paneResolution.paneFor = livePane;
  try {
    return await call("POST", "/api/events", { event: "working", ...body });
  } finally {
    paneResolution.paneFor = realPaneFor;
  }
}

// ---------------------------------------------------------------- the rules

test("the token is read out of a pane's environment", () => {
  assert.equal(parseSurfaceToken("AMA_SURFACE_TOKEN=abc123"), "abc123");
  assert.equal(parseSurfaceToken("PATH=/bin\nAMA_SURFACE_TOKEN=abc123\nSHELL=/bin/sh"), "abc123");
});

test("a pane that holds no token yields none", () => {
  assert.equal(parseSurfaceToken(""), null);
  assert.equal(parseSurfaceToken("PATH=/bin"), null);
  assert.equal(parseSurfaceToken("-AMA_SURFACE_TOKEN"), null);
  assert.equal(parseSurfaceToken("AMA_SURFACE_TOKEN="), null);
  assert.equal(parseSurfaceToken(null), null);
});

test("a similarly named variable is not the token", () => {
  assert.equal(parseSurfaceToken("AMA_SURFACE_TOKEN_EXTRA=nope"), null);
  assert.equal(parseSurfaceToken("X_AMA_SURFACE_TOKEN=nope"), null);
});

test("a token nobody knows is adopted", () => {
  const plan = planAdoptions([{ name: "slice", token: "tok-1" }], new Map());
  assert.deepEqual(plan.bindings, [{ token: "tok-1", name: "slice" }]);
  assert.equal(plan.adopted.length, 1);
  assert.equal(plan.skipped.length, 0);
});

test("adopting is additive — a known binding is never revoked or re-pointed", () => {
  const known = new Map([["tok-1", "slice"]]);
  const same = planAdoptions([{ name: "slice", token: "tok-1" }], known);
  assert.equal(same.bindings.length, 0);
  assert.equal(same.skipped[0].reason, "already-known");

  const elsewhere = planAdoptions([{ name: "other", token: "tok-1" }], known);
  assert.equal(elsewhere.bindings.length, 0);
  assert.equal(elsewhere.skipped[0].reason, "bound-elsewhere");
  assert.equal(known.get("tok-1"), "slice", "the original binding survives");
});

test("the same pair twice in one batch is adopted once", () => {
  const plan = planAdoptions(
    [
      { name: "slice", token: "tok-1" },
      { name: "slice", token: "tok-1" },
    ],
    new Map(),
  );
  assert.equal(plan.bindings.length, 1);
  assert.equal(plan.skipped[0].reason, "duplicate");
});

test("an entry without a token is skipped", () => {
  const plan = planAdoptions([{ name: "slice", token: null }], new Map());
  assert.equal(plan.bindings.length, 0);
  assert.equal(plan.skipped[0].reason, "no-token");
});

test("a session with a known token uses it, one that still holds one adopts it, one with neither mints", () => {
  assert.deepEqual(recoveryAction({ name: "a", token: "held", knownToken: "known" }), {
    action: "use",
    token: "known",
  });
  assert.deepEqual(recoveryAction({ name: "a", token: "held", knownToken: null }), {
    action: "adopt",
    token: "held",
  });
  assert.deepEqual(recoveryAction({ name: "a", token: null, knownToken: null }), {
    action: "mint",
    token: null,
  });
});

test("a token is swept for once", () => {
  const swept = new Set();
  assert.equal(shouldSweep({ token: "tok-1", sweptTokens: swept }), true);
  swept.add("tok-1");
  assert.equal(shouldSweep({ token: "tok-1", sweptTokens: swept }), false);
  assert.equal(shouldSweep({ token: "tok-2", sweptTokens: swept }), true);
});

// --------------------------------------------------------- through the API

test("a token the server forgot is re-learned from the pane, and its task is accepted", async () => {
  stubTmux();
  tmuxSessions.add("stale-slice");
  tmuxEnv.set("stale-slice", `${SURFACE_TOKEN_ENV}=tok-stale`);

  const res = await postEvent({ surfaceToken: "tok-stale", task: "Recovered" });

  assert.equal(res.statusCode, 200);
  assert.equal(res.payload.task, "Recovered");
  assert.equal(surfaceTokens.get("tok-stale"), "stale-slice");
});

test("a session with no token at all is given one on first contact", async () => {
  stubTmux();
  tmuxSessions.add("foreign-slice");

  // First contact: no token, so no task can be reported yet.
  const first = await postEvent({ sessionId: "ses_foreign" });
  assert.equal(first.statusCode, 200);
  assert.equal(published.length, 1);
  assert.equal(published[0].name, "foreign-slice");
  const minted = published[0].token;

  // The next report carries the token the pane now holds.
  const second = await postEvent({ sessionId: "ses_foreign", surfaceToken: minted, task: "Hello" });
  assert.equal(second.statusCode, 200);
  assert.equal(second.payload.task, "Hello");
});

test("a task reported without a token is refused even when the session has one", async () => {
  stubTmux();
  tmuxSessions.add("mine-slice");
  tmuxEnv.set("mine-slice", `${SURFACE_TOKEN_ENV}=tok-mine`);
  surfaceTokens.set("tok-mine", "mine-slice");

  const res = await postEvent({ sessionId: "ses_mine", task: "Spoofed" });

  assert.equal(res.statusCode, 403);
  assert.equal(res.payload.error, "Task requires a surface token");
});

test("a sweep adopts what the panes hold without disturbing what it already knows", async () => {
  stubTmux();
  tmuxSessions.add("session-a");
  tmuxSessions.add("session-b");
  tmuxEnv.set("session-a", `${SURFACE_TOKEN_ENV}=tok-a`);
  tmuxEnv.set("session-b", `${SURFACE_TOKEN_ENV}=tok-b`);
  surfaceTokens.set("tok-a", "session-a");

  // An unknown token triggers the sweep; the report itself cannot be resolved.
  const res = await postEvent({ surfaceToken: "tok-nowhere" });
  assert.equal(res.statusCode, 422);

  assert.equal(surfaceTokens.get("tok-a"), "session-a", "the known binding is untouched");
  assert.equal(surfaceTokens.get("tok-b"), "session-b", "the held token was adopted");
});
