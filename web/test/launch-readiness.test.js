// A slow shell is not a failed launch, and a failed launch leaves nothing
// behind. The readiness check used to accept *any* captured content on a 5 s
// budget polled every 25 ms — tighter than the cost of a poll — so a slow
// shell sat right on its deadline and a genuinely failed launch left the
// half-created tmux session behind, registered as a plain shell.
//
// server.js guards app.listen behind NODE_ENV !== "test", so importing it is
// safe and does not listen. The readiness capture is a seam the suite points
// at a stub, so these tests run without a live tmux pane — except where the
// test says otherwise, because "no session left behind" is a claim about a
// real tmux server.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, writeFileSync } from "node:fs";
import { accessSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const execFile = promisify(execFileCb);
const logDir = mkdtempSync(join(tmpdir(), "ama-launch-readiness-"));
process.env.ALL_MY_AGENTS_LOG_DIR = logDir;
process.env.ALL_MY_AGENTS_REGISTRY_POLL_MS = "3600000";
writeFileSync(join(logDir, "active-sessions.json"), JSON.stringify({ version: 2, updatedAt: Date.now(), sessions: [] }));

process.env.NODE_ENV = "test";
const { app, launching, tmuxOps, paneReadiness } = await import("../server.js");

const TMUX = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].find((p) => {
  try { accessSync(p); return true; } catch { return false; }
});
const realWait = paneReadiness.waitForShellPrompt;
const realCapture = paneReadiness.paneCapture.run;

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

test.afterEach(() => {
  paneReadiness.waitForShellPrompt = realWait;
  paneReadiness.paneCapture.run = realCapture;
});

test("a shell prompt at the end of the pane's content is ready", () => {
  // The prompt this machine's zsh draws.
  assert.equal(paneReadiness.isShellPrompt("andy@AMER-CY4DQ52L6C Repos %"), true);
  // A starship-style prompt, a bare prompt character, and a bash prompt.
  assert.equal(paneReadiness.isShellPrompt("❯"), true);
  assert.equal(paneReadiness.isShellPrompt("user@host:~$"), true);
  // Trailing blank lines — the pane pad — do not hide the prompt.
  assert.equal(paneReadiness.isShellPrompt("andy@host Repos %\n\n\n"), true);
});

test("content that is not a prompt is not ready", () => {
  // A login banner: the shell has printed something but drawn no prompt.
  // Typing into it echoes the command twice and can lose characters.
  assert.equal(paneReadiness.isShellPrompt("Last login: Thu Nov 20 22:00:00 on ttys000\nWelcome to macOS"), false);
  // A half-drawn prompt: no prompt character yet.
  assert.equal(paneReadiness.isShellPrompt("andy@AMER-CY4DQ52L6C Repos "), false);
  // Nothing drawn at all.
  assert.equal(paneReadiness.isShellPrompt(""), false);
  assert.equal(paneReadiness.isShellPrompt(undefined), false);
});

test("the readiness window is generous and the poll is not tighter than a poll costs", () => {
  // A poll costs roughly a quarter of a second (a process spawn); the old
  // 25 ms interval could never keep up with itself.
  assert.ok(paneReadiness.pollMs >= 250, `poll interval ${paneReadiness.pollMs}ms is tighter than a poll costs`);
  // The old window was five seconds — right on the deadline a slow shell hit.
  assert.ok(paneReadiness.timeoutMs >= 20_000, `readiness window ${paneReadiness.timeoutMs}ms is too short for a slow shell`);
});

test("a pane whose prompt appears late is waited for", async () => {
  let calls = 0;
  paneReadiness.paneCapture.run = async () => {
    calls += 1;
    return calls < 3 ? "" : "andy@AMER-CY4DQ52L6C Repos %";
  };
  assert.equal(await paneReadiness.waitForShellPrompt("%9", 5000, 10), true);
  assert.ok(calls >= 3, "the check gave up before the prompt appeared");
});

test("a pane that never draws a prompt is not ready", async () => {
  let calls = 0;
  paneReadiness.paneCapture.run = async () => { calls += 1; return ""; };
  const started = Date.now();
  assert.equal(await paneReadiness.waitForShellPrompt("%9", 150, 40), false);
  assert.ok(calls >= 2, "the check stopped polling before the deadline");
  assert.ok(Date.now() - started >= 80, "the check returned before polling more than once");
});

test("a launch that never becomes ready destroys the half-created session", async () => {
  if (!TMUX) return;
  const name = `amtest-orphan-${process.pid}`;
  paneReadiness.waitForShellPrompt = async () => false;
  await assert.rejects(
    launching.pane({ name, token: "tok-orphan", command: "echo hi" }),
    { message: "the pane's shell never became ready" },
  );
  await assert.rejects(
    execFile(TMUX, ["has-session", "-t", name]),
    { code: 1 },
    "the half-created tmux session survived a failed launch",
  );
});

test("a failed launch answers 500 with the same message and leaves no session", async () => {
  if (!TMUX) return;
  const name = `amtest-route-fail-${process.pid}`;
  paneReadiness.waitForShellPrompt = async () => false;
  const { statusCode, payload } = await call("POST", "/api/sessions", { name, command: "echo hi" });
  assert.equal(statusCode, 500);
  assert.equal(payload.error, "the pane's shell never became ready");
  await assert.rejects(
    execFile(TMUX, ["has-session", "-t", name]),
    { code: 1 },
    "the half-created tmux session survived a failed launch",
  );
});

test("a pane whose prompt arrives late launches successfully", async () => {
  if (!TMUX) return;
  const name = `amtest-late-${process.pid}`;
  paneReadiness.waitForShellPrompt = async () => true;
  try {
    const { statusCode, payload } = await call("POST", "/api/sessions", { name, command: "echo hi" });
    assert.equal(statusCode, 200);
    assert.equal(payload.ok, true);
    assert.equal(payload.name, name);
  } finally {
    await execFile(TMUX, ["kill-session", "-t", name]).catch(() => {});
  }
});
