// Messages an agent reports about its own output, filed against the session
// NAME the event resolved to (see ADR 0013: agents report their own output,
// so a client can read a reply as text instead of diffing the pane).
//
// Pure and in-memory: a server restart loses the history, and a client asking
// for a message that is not there gets an empty list — that empty list is the
// fallback path for agents that do not report their output, not a fault.
//
// `id` increases within a session, so a cursor stays stable across reads:
// `messages(name, since)` is everything after `since`, oldest first.
//
// `origin` records where the message came from — "panel" for a reply typed in
// the chat panel, "agent" for the agent's own reported output, and null when
// nobody said. Reading it is the consumer's job: the store only records.
//
// A repeat of an agent message is not filed again. Claude Code fires its
// Stop hook twice for one turn — once after the assistant's text, once after
// a tool-use turn — each carrying the same last_assistant_message, so the
// same text can arrive twice for one thing the agent said. Within
// DEDUPE_WINDOW_MS of the session's previous message, agent-origin text
// identical to it is recognised as that message: `file` answers the first
// filing's id and nothing new is stored, so the panel and the transcript
// read one message where the hook delivered two. A repeat outside the window
// is the agent saying it again, and is filed. Only agent-origin messages are
// concerned: a panel reply is always stored, and never treated as a repeat
// of an agent message. The window is short and the comparison is exact.
// The clock is injected (`now`) so tests can walk up to and past the window
// without sleeping.

// The dedupe window, in ms. How long after a message an identical agent
// filing counts as that message instead of a new one. It lives here, at the
// store where the repeat is recognised — not buried in the comparison.
const DEDUPE_WINDOW_MS = 10_000;

export function createMessageStore({ now = Date.now, dedupeWindowMs = DEDUPE_WINDOW_MS } = {}) {
  // session name → filed messages, oldest first
  const filed = new Map();
  // session name → id of the last message filed
  const cursor = new Map();

  function file(name, text, origin = null) {
    const list = filed.get(name) ?? [];
    const last = list[list.length - 1];
    if (
      origin === "agent" &&
      last?.origin === "agent" &&
      last.text === text &&
      now() - last.at <= dedupeWindowMs
    ) {
      // The hook delivered the same message again: answer the first
      // filing's id and keep the stored message as it was filed.
      return last.id;
    }
    const id = (cursor.get(name) ?? 0) + 1;
    cursor.set(name, id);
    list.push({ id, text, at: now(), origin });
    filed.set(name, list);
    return id;
  }

  function messages(name, since) {
    const list = filed.get(name) ?? [];
    return since === undefined ? [...list] : list.filter((m) => m.id > since);
  }

  function latestId(name) {
    return cursor.get(name) ?? null;
  }

  function clear(name) {
    filed.delete(name);
    cursor.delete(name);
  }

  return { file, messages, latestId, clear };
}
