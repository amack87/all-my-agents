// Pure ordering model for the sidebar (groups + ungrouped region).
//
// DOM-free on purpose: public/app.js owns all Pointer Events wiring and passes
// session objects plus a keyOf(session) callback; this module only transforms
// the persisted group-data structure:
//
//   { groups: { name: [key, ...] }, collapsed: { name: bool },
//     order: [groupName, ...], ungroupedOrder: [key, ...],
//     serverGroups: [groupName, ...] }
//
// Membership is server-declared (ADR 0017, which amends ADR 0006): a session
// carries the `group` it belongs to and renders there, wherever this surface's
// store says it used to sit. What the store keeps is the user's — the group
// list (`order`), the order inside a group (`groups`), the collapsed flags and
// the ungrouped order — plus `serverGroups`, the record of group names adopted
// from session declarations rather than created by James. Manual order wins:
// nothing here reads a session's status, so tiles never move themselves. See
// ../CONTEXT.md and ../docs/adr/0001-manual-sidebar-order.md.

import { isSafeGroupName } from "./sidebar-sync.js";

export function createEmptyOrder() {
  return { groups: {}, collapsed: {}, order: [], ungroupedOrder: [], serverGroups: [] };
}

function normalize(data) {
  const src = data && typeof data === "object" ? data : {};
  const groups = {};
  if (src.groups && typeof src.groups === "object") {
    for (const [name, members] of Object.entries(src.groups)) {
      if (!isSafeGroupName(name)) continue;
      groups[name] = Array.isArray(members) ? [...members] : [];
    }
  }
  const collapsed = {};
  if (src.collapsed && typeof src.collapsed === "object") {
    for (const [name, value] of Object.entries(src.collapsed)) {
      if (!isSafeGroupName(name)) continue;
      collapsed[name] = !!value;
    }
  }
  const order = Array.isArray(src.order)
    ? src.order.filter((n) => typeof n === "string" && isSafeGroupName(n))
    : [];
  const ungroupedOrder = Array.isArray(src.ungroupedOrder)
    ? src.ungroupedOrder.filter((k) => typeof k === "string")
    : [];
  // A server-declared group that James has claimed lives in `order`, so an
  // adopted name that also appears there is not an adoption any more.
  const claimed = new Set(order);
  const serverGroups = Array.isArray(src.serverGroups)
    ? [...new Set(src.serverGroups.filter((n) => typeof n === "string" && isSafeGroupName(n) && !claimed.has(n)))]
    : [];
  const next = { groups, collapsed, order, ungroupedOrder, serverGroups };
  return next;
}

function clamp(index, length) {
  const i = Number.isInteger(index) ? index : length;
  return Math.max(0, Math.min(i, length));
}

function nameOfKey(key) {
  return key.includes("::") ? key.split("::").slice(1).join("::") : key;
}

/**
 * Move a session key to `target` (a group name, or null/undefined for the
 * ungrouped region) at position `index`. Returns a new data object.
 */
export function moveSession(data, key, target, index) {
  const next = normalize(data);
  // A name that cannot be stored as an object key is not a group. Moving a
  // session into it would silently do nothing, so it lands ungrouped instead.
  const groupTarget = target == null ? null : (isSafeGroupName(target) ? target : null);

  for (const name of Object.keys(next.groups)) {
    next.groups[name] = next.groups[name].filter((k) => k !== key);
  }
  next.ungroupedOrder = next.ungroupedOrder.filter((k) => k !== key);

  if (groupTarget == null) {
    const at = clamp(index, next.ungroupedOrder.length);
    next.ungroupedOrder.splice(at, 0, key);
  } else {
    if (!next.groups[groupTarget]) next.groups[groupTarget] = [];
    // Acting on a group claims it: it moves out of the adoption record into
    // James's own group list, so the sidebar stops marking it server-declared.
    next.serverGroups = next.serverGroups.filter((n) => n !== groupTarget);
    if (!next.order.includes(groupTarget)) next.order.push(groupTarget);
    const at = clamp(index, next.groups[groupTarget].length);
    next.groups[groupTarget].splice(at, 0, key);
  }
  return next;
}

/** Reorder a group among its peers. Returns a new data object. */
export function moveGroup(data, name, index) {
  const next = normalize(data);
  if (!isSafeGroupName(name)) return next;
  // Reordering a group claims it, the same way acting on a session does.
  next.serverGroups = next.serverGroups.filter((n) => n !== name);
  next.order = next.order.filter((n) => n !== name);
  for (const groupName of Object.keys(next.groups)) {
    if (groupName !== name && !next.order.includes(groupName)) next.order.push(groupName);
  }
  const at = clamp(index, next.order.length);
  next.order.splice(at, 0, name);
  return next;
}

/**
 * Reconcile stored keys against the live sessions and resolve the render view,
 * merging the sessions' server-declared membership with the manual order.
 *
 * - stored keys whose session is absent are kept (so a returning session gets
 *   its old slot back)
 * - a stored key whose session reappears under a different machine host is
 *   rewritten to the new key, keeping its slot
 * - a session's declared group is where it renders: a member arriving joins
 *   the END of its group's order, so the members already there never shuffle
 * - a declared group the store has never seen is adopted into `serverGroups`
 *   and rendered after James's own groups, marked server-declared
 * - a live session that declares no group is re-homed to the ungrouped region
 *   (membership used to be client-owned; the server is the authority now)
 * - a server-declared group whose members are all gone loses its adoption —
 *   membership lives on the sessions, so it disappears with them
 * - group names stored before this resolve and missing from `order` are
 *   appended (James's own groups never silently vanish)
 *
 * Returns { data, groups, ungrouped, changed } where `groups` is
 * [{ name, collapsed, serverDeclared, sessions }] in render order (empty
 * user groups included).
 */
export function resolveOrder(data, sessions, keyOf = (s) => s.key) {
  const next = normalize(data);
  const list = Array.isArray(sessions) ? sessions : [];

  const keyToSession = new Map();
  const nameToSession = new Map();
  for (const session of list) {
    const k = keyOf(session);
    if (!keyToSession.has(k)) keyToSession.set(k, session);
    if (session && typeof session.name === "string" && !nameToSession.has(session.name)) {
      nameToSession.set(session.name, session);
    }
  }

  let changed = false;

  const reconcileKey = (storedKey) => {
    if (keyToSession.has(storedKey)) return storedKey;
    const match = nameToSession.get(nameOfKey(storedKey));
    if (!match) return storedKey;
    const newKey = keyOf(match);
    if (newKey !== storedKey) changed = true;
    return newKey;
  };

  const seen = new Set();

  for (const name of Object.keys(next.groups)) {
    const stored = next.groups[name];
    const resolved = [];
    for (const k of stored) {
      const rk = reconcileKey(k);
      if (seen.has(rk)) {
        changed = true;
        continue;
      }
      seen.add(rk);
      resolved.push(rk);
    }
    if (resolved.length !== stored.length) changed = true;
    next.groups[name] = resolved;
  }

  const ungroupedResolved = [];
  for (const k of next.ungroupedOrder) {
    const rk = reconcileKey(k);
    if (seen.has(rk)) {
      changed = true;
      continue;
    }
    seen.add(rk);
    ungroupedResolved.push(rk);
  }
  if (ungroupedResolved.length !== next.ungroupedOrder.length) changed = true;
  next.ungroupedOrder = ungroupedResolved;

  // Membership merge. The stored keys were reconciled first, so this pass
  // re-homes live sessions by what the server declares, not by what a stale
  // copy of the store says.
  const declaredOf = (session) =>
    session && isSafeGroupName(session.group) ? session.group : null;
  const storedGroupNames = new Set(Object.keys(next.groups));
  const storedUngrouped = new Set(next.ungroupedOrder);
  const freshUngrouped = [];

  for (const session of list) {
    const k = keyOf(session);
    const declared = declaredOf(session);
    if (declared == null) {
      // No declaration: the tile belongs in the ungrouped region. It must not
      // be held by a group the store remembers from a client-owned past.
      for (const name of Object.keys(next.groups)) {
        if (!next.groups[name].includes(k)) continue;
        next.groups[name] = next.groups[name].filter((key) => key !== k);
        changed = true;
      }
      if (!storedUngrouped.has(k)) freshUngrouped.push(k);
      continue;
    }
    // Adopt a group name no copy of the store has arranged yet.
    if (!next.order.includes(declared) && !next.serverGroups.includes(declared)) {
      next.serverGroups = [...next.serverGroups, declared];
      changed = true;
    }
    if (!next.groups[declared]) next.groups[declared] = [];
    // The session leaves every group it does not declare.
    for (const name of Object.keys(next.groups)) {
      if (name === declared || !next.groups[name].includes(k)) continue;
      next.groups[name] = next.groups[name].filter((key) => key !== k);
      changed = true;
    }
    // A member arriving appends after the existing members: their order —
    // James's — is left alone.
    if (!next.groups[declared].includes(k)) {
      next.groups[declared] = [...next.groups[declared], k];
      changed = true;
    }
  }

  // Sessions whose declared home is the ungrouped region and that have no
  // stored ungrouped slot seed at the top, in session-list order.
  if (freshUngrouped.length) {
    next.ungroupedOrder = [...freshUngrouped, ...next.ungroupedOrder];
    changed = true;
  }

  // Group names the store already arranged but that `order` lost are still
  // James's own: they rejoin the group list. Names adopted this resolve are
  // not claimed by it.
  for (const groupName of Object.keys(next.groups)) {
    if (storedGroupNames.has(groupName) || next.order.includes(groupName)) continue;
    if (next.serverGroups.includes(groupName)) continue;
    next.order.push(groupName);
    changed = true;
  }
  for (const groupName of storedGroupNames) {
    if (!next.order.includes(groupName) && !next.serverGroups.includes(groupName)) {
      next.order.push(groupName);
      changed = true;
    }
  }

  // Membership lives on the sessions (ADR 0017): a server-declared group whose
  // members have all gone loses its adoption and leaves no ordering residue.
  next.serverGroups = next.serverGroups.filter((name) => {
    if (list.some((session) => declaredOf(session) === name)) return true;
    delete next.groups[name];
    changed = true;
    return false;
  });

  const groupSessions = (name) =>
    (next.groups[name] || [])
      .map((k) => keyToSession.get(k))
      .filter((session) => session && declaredOf(session) === name);

  // Render James's groups in his order, then the adopted (server-declared)
  // ones in adoption order.
  const groups = [
    ...next.order.map((name) => ({
      name,
      collapsed: !!next.collapsed[name],
      serverDeclared: false,
      sessions: groupSessions(name),
    })),
    ...next.serverGroups
      .filter((name) => !next.order.includes(name))
      .map((name) => ({
        name,
        collapsed: !!next.collapsed[name],
        serverDeclared: true,
        sessions: groupSessions(name),
      })),
  ];

  const ungrouped = next.ungroupedOrder
    .map((k) => keyToSession.get(k))
    .filter((session) => session && declaredOf(session) == null);

  return { data: next, groups, ungrouped, changed };
}