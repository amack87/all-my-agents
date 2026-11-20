// All My Agents — opencode status adapter
//
// opencode plugin that reports opencode session lifecycle as All My Agents
// "canonical status events", so the sidebar reflects working / needs-input /
// idle without scraping the screen.
//
// Install: copy this file into opencode's global plugin directory, e.g.
//   ~/.config/opencode/plugin/ama-status.js      (older opencode: singular)
//   ~/.config/opencode/plugins/ama-status.js     (newer opencode: plural)
// On this machine opencode 1.18.35 loads `~/.config/opencode/plugin/`.
// A project-local `.opencode/plugin(s)/` copy works the same way.
//
// It is standalone and dependency-free. It fails open: if AMA is unreachable
// (or rejects the event because the session is unknown), opencode is
// completely unaffected.
//
// NOTE ON SHAPE: opencode's plugin loader reads the module's DEFAULT export
// (opencode 1.19 and later) and ignores the named ones, so the plugin is
// exported both ways: the default is what opencode loads, the named export
// is what the unit tests import. The pure mapping helpers the tests need
// hang off that function as `AmaStatusPlugin.helpers`.

const POST_TIMEOUT_MS = 1500;

const BUS_EVENTS = {
  "session.created": "sessionStart",
  "session.idle": "stop",
  "session.deleted": "sessionEnd",
  "permission.updated": "permissionRequest",
  "permission.asked": "permissionRequest",
};

const HOOK_EVENTS = {
  "chat.message": "promptSubmit",
  "tool.execute.before": "toolStart",
  "tool.execute.after": "toolEnd",
  "permission.ask": "permissionRequest",
};

function canonicalBusEvent(type) {
  return BUS_EVENTS[type] ?? null;
}

function sessionIdFromBusProps(event) {
  const properties = event?.properties;
  if (!properties || typeof properties !== "object") return null;
  if (typeof properties.sessionID === "string") return properties.sessionID;

  const info = properties.info;
  if (info && typeof info === "object") {
    if (typeof info.sessionID === "string") return info.sessionID;
    if (typeof info.id === "string") return info.id;
  }

  const part = properties.part;
  if (part && typeof part === "object" && typeof part.sessionID === "string") {
    return part.sessionID;
  }

  return null;
}

function resolveBaseUrl(env) {
  if (env?.ALL_MY_AGENTS_URL) return String(env.ALL_MY_AGENTS_URL).replace(/\/+$/, "");
  return `http://127.0.0.1:${env?.ALL_MY_AGENTS_PORT ?? 3456}`;
}

// The pane's surface token. AMA exports it into the pane it launches, so an
// agent running in an AMA-managed pane can name itself exactly, instead of
// being identified by a session id that anything else could guess.
function resolveToken(env) {
  const token = env?.AMA_SURFACE_TOKEN;
  return typeof token === "string" && token !== "" ? token : null;
}

// The body AMA's event endpoint accepts: an event, the session it is about,
// the surface token when the agent has one, and the assistant's reply when
// the event ends a turn. The message stays OPTIONAL: an adapter that cannot
// supply one (or an event that is not a reply) sends the same body it always
// did — the same rule the Claude Code hook follows.
function buildBody(event, sessionId, token, message) {
  const body = { event, sessionId };
  if (token) body.surfaceToken = token;
  if (typeof message === "string" && message) body.message = message;
  return body;
}

// The text of an assistant's reply, read straight out of the message the bus
// already carries. Only assistant messages have a reply, and only their text
// parts are speech; blank or malformed fields mean no message — the same
// rule the Claude Code hook applies to `last_assistant_message`.
function assistantText(info) {
  if (!info || info.role !== "assistant" || !Array.isArray(info.parts)) return null;
  const text = info.parts
    .filter((part) => part?.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n\n");
  return text.trim() ? text : null;
}

// Replies are remembered between events: the bus reports the assistant's
// message while it streams, but the turn ends on a different event
// (session.idle → stop). opencode publishes the completed message BEFORE the
// session goes idle, so the text observed last is the reply the stop event
// carries. Taken once, then forgotten — a reply belongs to one turn.
function createReplyTracker() {
  const replies = new Map();
  const assistants = new Map();
  return {
    observe(busEvent) {
      const properties = busEvent?.properties;
      const type = busEvent?.type;
      const sessionId = sessionIdFromBusProps(busEvent);
      if (!sessionId) return;
      if (type === "message.updated") {
        if (properties?.info?.role !== "assistant") return;
        // The id of the message the agent is speaking in: the parts that
        // follow belong to it.
        const id = properties.info?.id;
        if (id) {
          const ids = assistants.get(sessionId) ?? new Set();
          ids.add(id);
          assistants.set(sessionId, ids);
        }
        // Older opencode carries the text inside the message itself.
        const text = assistantText(properties.info);
        if (text) replies.set(sessionId, text);
        return;
      }
      if (type === "message.part.updated") {
        // opencode 1.19 and later: the text arrives as a part of the
        // message, not inside it, so the reply is read from the part — and
        // only from the agent's own message, never the person's.
        const part = properties?.part;
        if (part?.type !== "text" || typeof part.text !== "string") return;
        const ids = assistants.get(sessionId);
        if (!ids || !part.messageID || !ids.has(part.messageID)) return;
        replies.set(sessionId, part.text);
      }
    },
    take(sessionId) {
      const text = replies.get(sessionId);
      replies.delete(sessionId);
      return text ?? null;
    },
    forget(sessionId) {
      replies.delete(sessionId);
      assistants.delete(sessionId);
    },
  };
}

export const AmaStatusPlugin = async () => {
  const env = globalThis.process?.env ?? {};
  const baseUrl = resolveBaseUrl(env);
  const token = resolveToken(env);

  const started = new Set();
  const chains = new Map();
  const replies = createReplyTracker();

  async function post(event, sessionId, message) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), POST_TIMEOUT_MS);
    try {
      await fetch(`${baseUrl}/api/events`, {
        method: "POST",
        headers: {"content-type":"application/json"},
        body: JSON.stringify(buildBody(event, sessionId, token, message)),
        signal: controller.signal,
      });
    } catch {
      // fail open: network error, timeout, or non-2xx all ignored
    } finally {
      clearTimeout(timer);
    }
  }

  function enqueue(sessionId, event, message) {
    const previous = chains.get(sessionId) ?? Promise.resolve();
    const next = previous.then(() => post(event, sessionId, message)).catch(() => {});
    chains.set(sessionId, next);
    return next;
  }

  function emit(sessionId, event, message) {
    if (!sessionId || !event) return;

    if (event === "sessionStart") {
      if (!started.has(sessionId)) {
        started.add(sessionId);
        enqueue(sessionId, "sessionStart");
      }
      return;
    }

    if (event === "sessionEnd") {
      if (started.has(sessionId)) {
        started.delete(sessionId);
        replies.forget(sessionId);
        enqueue(sessionId, "sessionEnd");
      }
      return;
    }

    // Any other event implies the session exists: announce it first so the
    // server never sees a prompt/tool event before its sessionStart.
    if (!started.has(sessionId)) {
      started.add(sessionId);
      enqueue(sessionId, "sessionStart");
    }
    enqueue(sessionId, event, message);
  }

  return {
    event: async ({ event }) => {
      // The assistant's reply is observed from the message bus itself: opencode
      // reports the completed message just before the session goes idle, so
      // the stop event this adapter already sends carries it — the same shape
      // Claude Code's Stop hook produces. The text arrives with the message
      // on older opencode and as a part of it on 1.19 and later, so both
      // are watched.
      if (event?.type === "message.updated" || event?.type === "message.part.updated") {
        replies.observe(event);
        return;
      }
      const canonical = canonicalBusEvent(event?.type);
      if (!canonical) return;
      const sessionId = sessionIdFromBusProps(event);
      const message = canonical === "stop" ? replies.take(sessionId) : null;
      if (canonical === "sessionStart") replies.forget(sessionId);
      emit(sessionId, canonical, message);
    },
    "chat.message": async (input) => {
      emit(input?.sessionID, HOOK_EVENTS["chat.message"]);
    },
    "tool.execute.before": async (input) => {
      emit(input?.sessionID, HOOK_EVENTS["tool.execute.before"]);
    },
    "tool.execute.after": async (input) => {
      emit(input?.sessionID, HOOK_EVENTS["tool.execute.after"]);
    },
    "permission.ask": async (input) => {
      emit(input?.sessionID, HOOK_EVENTS["permission.ask"]);
    },
    dispose: async () => {
      for (const sessionId of [...started]) emit(sessionId, "sessionEnd");
      await Promise.allSettled([...chains.values()]);
    },
  };
};

AmaStatusPlugin.helpers = {
  canonicalBusEvent,
  sessionIdFromBusProps,
  resolveBaseUrl,
  resolveToken,
  buildBody,
  assistantText,
  createReplyTracker,
  HOOK_EVENTS,
};

export default AmaStatusPlugin;
