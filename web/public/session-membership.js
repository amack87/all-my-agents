// Pure HTML fragments for how membership is shown (ADR 0017): a tile shows
// the group the server says it belongs to, and a group that exists because
// sessions declare it — rather than because James arranged it — is marked so
// he does not fight the app over a tile's home. DOM-free so the suite can
// assert what a person sees; app.js splices these into its card and header
// templates.

import { esc as escapeHtml } from "./escape.js";

/** The group a session declares, or null. The server is the authority. */
export function groupOf(session) {
  return session && typeof session.group === "string" && session.group !== ""
    ? session.group
    : null;
}

/** The badge a tile carries when the session declares a group. */
export function groupBadgeHtml(session) {
  const group = groupOf(session);
  if (group == null) return "";
  return `<span class="session-group-badge" title="Server-declared group">${escapeHtml(group)}</span>`;
}

/** The marker on a group header that exists only because the server declared its members. */
export function serverGroupTagHtml(group) {
  if (!group || !group.serverDeclared) return "";
  return `<span class="group-server-tag" title="Exists because the server declared its members">server</span>`;
}
