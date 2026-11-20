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

export function createMessageStore() {
  // session name → filed messages, oldest first
  const filed = new Map();
  // session name → id of the last message filed
  const cursor = new Map();

  function file(name, text, origin = null) {
    const list = filed.get(name) ?? [];
    const id = (cursor.get(name) ?? 0) + 1;
    cursor.set(name, id);
    list.push({ id, text, at: Date.now(), origin });
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
