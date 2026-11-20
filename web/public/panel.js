// The chat panel: the session's messages beside its terminal, with a composer
// that sends James's reply to the session. A reply typed here is sent with the
// panel's origin, so the record says where it came from; text typed into the
// terminal never carries it.
//
// The panel is a general tool: it works for any session, grouped or not, local
// or on a peer, and it knows nothing about tasks. It polls the session's
// message route with the cursor the route publishes, so a message appears
// without a refresh. The DOM wiring lives here; the pure parts are in
// chat-panel.js and needs-you.js.

import { esc } from "./escape.js";
import { messageLabel, appendMessages } from "./chat-panel.js";

const POLL_MS = 1000;
const SCROLL_SLACK_PX = 48;

const $ = (sel) => document.querySelector(sel);

let apiUrl = (p) => p;
let current = null; // { session, machineHost }
let messages = [];
let pollTimer = null;
let panelOpen = false;

function messageUrl(name, machineHost, since) {
  const base = machineHost && machineHost !== "local"
    ? apiUrl(`/api/proxy/${encodeURIComponent(machineHost)}/sessions/${encodeURIComponent(name)}/message`)
    : apiUrl(`/api/sessions/${encodeURIComponent(name)}/message`);
  return since === null ? base : `${base}?since=${since}`;
}

async function sendMessage(name, text, machineHost) {
  const url = machineHost && machineHost !== "local"
    ? apiUrl(`/api/proxy/${encodeURIComponent(machineHost)}/sessions/${encodeURIComponent(name)}/send`)
    : apiUrl(`/api/sessions/${encodeURIComponent(name)}/send`);
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text, origin: "panel" }),
  });
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload.error || `send failed (${res.status})`);
  }
}

function at(ms) {
  const d = new Date(ms);
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function messageRow(m, sessionName) {
  const mine = messageLabel(m, sessionName) === "You";
  return `
    <div class="chat-msg ${mine ? "from-panel" : "from-agent"}">
      <div class="chat-msg-head">
        <span class="chat-msg-who">${esc(messageLabel(m, sessionName))}</span>
        <span class="chat-msg-at">${esc(at(m.at))}</span>
      </div>
      <div class="chat-msg-text">${esc(m.text)}</div>
    </div>`;
}

function renderMessages() {
  const box = $("#chat-messages");
  const sessionName = current?.session ?? "";
  box.innerHTML = messages.map((m) => messageRow(m, sessionName)).join("");
}

function drawNew(payloadMessages) {
  const before = messages.length;
  messages = appendMessages(messages, payloadMessages);
  if (messages.length === before) return;
  const box = $("#chat-messages");
  const stick = box.scrollHeight - box.scrollTop - box.clientHeight < SCROLL_SLACK_PX * 4;
  renderMessages();
  if (stick) box.scrollTop = box.scrollHeight;
}

function showError(message) {
  const el = $("#chat-error");
  el.textContent = message;
  el.classList.remove("hidden");
  clearTimeout(showError.timer);
  showError.timer = setTimeout(() => el.classList.add("hidden"), 4000);
}

async function poll() {
  if (!current) return;
  const cursor = messages.length > 0 ? messages[messages.length - 1].id : null;
  try {
    const res = await fetch(messageUrl(current.session, current.machineHost, cursor));
    if (res.status === 404) {
      stopPolling();
      $("#chat-messages").insertAdjacentHTML("beforeend",
        '<div class="chat-note">This session is gone.</div>');
      return;
    }
    if (!res.ok) return; // transient — the next tick retries
    const payload = await res.json();
    drawNew(payload.messages);
  } catch { /* transient — the next tick retries */ }
}

function startPolling() {
  stopPolling();
  poll();
  pollTimer = setInterval(poll, POLL_MS);
}

function stopPolling() {
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = null;
}

async function retarget(session, machineHost) {
  stopPolling();
  current = { session, machineHost };
  messages = [];
  $("#chat-session-name").textContent = session;
  $("#chat-input").placeholder = `Reply to ${session}`;
  $("#chat-messages").innerHTML = "";
  startPolling();
}

/** Is the panel showing right now? */
export function chatPanelIsOpen() {
  return panelOpen;
}

/** Open the panel on a session (or retarget it if it is already open). */
export async function chatPanelOpen(session, machineHost = "local") {
  panelOpen = true;
  document.getElementById("terminal-view").classList.add("chat-open");
  await retarget(session, machineHost);
  window.dispatchEvent(new Event("resize"));
}

/** Close the panel and show the terminal. */
export function chatPanelClose() {
  panelOpen = false;
  document.getElementById("terminal-view").classList.remove("chat-open");
  stopPolling();
  current = null;
  messages = [];
  window.dispatchEvent(new Event("resize"));
}

/** Toggle the panel for the session it is wired to. */
export function chatPanelToggle(session, machineHost = "local") {
  if (panelOpen) chatPanelClose();
  else chatPanelOpen(session, machineHost);
}

// The terminal changed sessions (Next/Back/click): the panel follows, keeping
// its open state, because working a backlog means switching sessions without
// losing the conversation.
export function chatPanelSync(session, machineHost = "local") {
  if (panelOpen) retarget(session, machineHost);
}

// The terminal was torn down: stop the polling but keep the open state, so a
// reconnect reopens onto the same conversation.
export function chatPanelDetach() {
  stopPolling();
  current = null;
  messages = [];
}

/**
 * Wire the panel to the app: the URL builder it must call through. Call once
 * at startup. The toggle button stays with the app — only it knows which
 * session is active — and calls chatPanelToggle itself.
 */
export function initChatPanel({ url }) {
  apiUrl = url;

  $("#chat-composer").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!current) return;
    const input = $("#chat-input");
    const text = input.value;
    if (!text.trim()) return;
    input.value = "";
    try {
      await sendMessage(current.session, text, current.machineHost);
      // The filed reply comes back on the next poll, marked as from the panel.
    } catch (err) {
      showError(err.message);
      input.value = text; // give the text back — an unsent reply is not gone
    }
  });

  $("#chat-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      $("#chat-send").click();
    }
  });
}
