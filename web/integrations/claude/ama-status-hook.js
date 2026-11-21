// AMA status hook for Claude Code.
//
// Claude Code invokes this command for each configured hook event, passing the
// hook payload as JSON on stdin. We translate the Claude event name into AMA's
// canonical status vocabulary and POST it to the local AMA server, carrying the
// surface token that the pane was launched with. Claude Code has no session id
// that maps into AMA's registry, so the surface token *is* the identity.
//
// This file is standalone (no imports) and fails open: if there is no token, or
// the server is unreachable, it prints nothing and exits 0 so the agent is
// never blocked. The pane's screen-scraping fallback covers any gap.
//
// Install: point Claude's hook settings at this file (see
// integrations/claude/settings.example.json and the README). The running
// process inherits AMA_SURFACE_TOKEN from the tmux pane environment.

import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";


// Must match SURFACE_TOKEN_ENV in ../../surface-token.js. Declared locally so
// the hook stays a self-contained drop-in with no relative imports.
const SURFACE_TOKEN_ENV = "AMA_SURFACE_TOKEN";

const POST_TIMEOUT_MS = 1500;
const TMUX_TIMEOUT_MS = 500;


// Claude hook event name -> canonical AMA event. Anything absent is ignored.
const HOOK_EVENT_MAP = {
  SessionStart: "sessionStart",
  UserPromptSubmit: "promptSubmit",
  PreToolUse: "toolStart",
  PostToolUse: "toolEnd",
  PermissionRequest: "permissionRequest",
  Notification: "notification",
  Stop: "stop",
  SessionEnd: "sessionEnd",
};

// Tools that mean Claude is asking the user a question or waiting on approval —
// those turn a PreToolUse into a "needs input" signal rather than telemetry.
const ATTENTION_TOOLS = new Set(["AskUserQuestion", "ExitPlanMode"]);

function mapHookEvent(payload) {
  if (!payload || typeof payload !== "object") return null;
  const name = payload.hook_event_name || payload.event;
  if (name === "PreToolUse" && ATTENTION_TOOLS.has(payload.tool_name)) {
    return "permissionRequest";
  }
  return HOOK_EVENT_MAP[name] || null;
}

// These read the environment they are given. The ambient environment is
// passed in explicitly at the call site, so a token inherited by every
// descendant process of the pane is a deliberate dependency rather than a
// hidden default.
// The token in the pane's own environment, if the process inherited it.
function tokenFromEnv(env) {
  if (!env) return null;
  const token = env[SURFACE_TOKEN_ENV];
  return typeof token === "string" && token.length > 0 ? token : null;
}

// A pane AMA did not launch has no token in the process environment, but the
// session may still hold one: `tmux set-environment` publishes a token to the
// session, so a process started after that sees it. The environment lives on
// the SESSION, not the pane, so the pane's session is resolved first.
function readTokenFromTmux(env) {
  const pane = env?.TMUX_PANE;
  if (!pane) return null;
  try {
    const session = execFileSync("tmux", ["display-message", "-p", "-t", pane, "#{session_name}"], {
      encoding: "utf8",
      timeout: TMUX_TIMEOUT_MS,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!session) return null;
    const output = execFileSync("tmux", ["show-environment", "-t", session, SURFACE_TOKEN_ENV], {
      encoding: "utf8",
      timeout: TMUX_TIMEOUT_MS,
      stdio: ["ignore", "pipe", "ignore"],
    });
    for (const line of String(output).split("\n")) {
      const trimmed = line.trim();
      if (!trimmed.startsWith(`${SURFACE_TOKEN_ENV}=`)) continue;
      const value = trimmed.slice(SURFACE_TOKEN_ENV.length + 1);
      return value.length > 0 ? value : null;
    }
  } catch {
    // No tmux, or the session is gone. Either way there is no token.
  }
  return null;
}

// The token the pane reports with: the one it inherited, or the one its
// session holds. `readTmux` is injectable so the fallback can be tested
// without tmux.
function resolveToken(env, { readTmux = readTokenFromTmux } = {}) {
  return tokenFromEnv(env) ?? readTmux(env);
}

function resolveBaseUrl(env) {
  if (!env) return `http://127.0.0.1:3456`;
  if (env.ALL_MY_AGENTS_URL) {
    return env.ALL_MY_AGENTS_URL.replace(/\/+$/, "");
  }
  return `http://127.0.0.1:${env.ALL_MY_AGENTS_PORT ?? 3456}`;
}

// The final response Claude gave the user. Claude Code documents that the
// Stop (and SubagentStop) hook payload carries `last_assistant_message` —
// the text content of Claude's final response — so the hook never has to
// read the transcript file. Blank or malformed fields mean no message.
function assistantMessage(payload) {
  if (!payload || typeof payload !== "object") return null;
  const text = payload.last_assistant_message;
  return typeof text === "string" && text.trim() ? text : null;
}

// Only the turn's end carries the reply: the `stop` event is the mapped form
// of Claude's Stop hook, and anything else (a prompt, a tool call) is not the
// answer to the user's question.
function messageFor(event, payload) {
  return event === "stop" ? assistantMessage(payload) : null;
}

function buildBody(event, token, message) {
  const body = { event, surfaceToken: token };
  if (typeof message === "string" && message) body.message = message;
  return body;
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  const raw = await readStdin();
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return;
  }
  const event = mapHookEvent(payload);
  const token = resolveToken(globalThis.process?.env);
  if (!event || !token) return;

  const body = buildBody(event, token, messageFor(event, payload));

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), POST_TIMEOUT_MS);
  try {
    await fetch(`${resolveBaseUrl(globalThis.process?.env)}/api/events`, {
      method: "POST",
      headers: {"content-type":"application/json"},
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch {
    // fail open — never block or error the agent
  } finally {
    clearTimeout(timer);
  }
}

const isMain =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch(() => {}).finally(() => process.exit(0));
}

export { HOOK_EVENT_MAP, mapHookEvent, resolveToken, resolveBaseUrl, assistantMessage, messageFor, buildBody };