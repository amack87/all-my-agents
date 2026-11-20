import Foundation

// Pure ordering model for the sidebar (groups + ungrouped region).
// Direct port of the web app's public/session-order.js so both apps share
// one persisted format and identical semantics:
//
//   { groups: { name: [key, ...] }, collapsed: { name: bool },
//     order: [groupName, ...], ungroupedOrder: [key, ...] }
//
// Manual order wins: nothing here reads a session's status, so tiles never
// move themselves (see the web repo's docs/adr/0001-manual-sidebar-order.md).

/// Persisted sidebar order structure — exactly the web app's JSON shape.
struct SidebarOrderData: Codable, Equatable {
    var groups: [String: [String]]
    var collapsed: [String: Bool]
    var order: [String]
    var ungroupedOrder: [String]

    static func empty() -> SidebarOrderData {
        SidebarOrderData(groups: [:], collapsed: [:], order: [], ungroupedOrder: [])
    }
}

/// Sync envelope shared with the web server: the order data plus the ms-epoch
/// time it was last written, used for last-writer-wins merges.
struct SidebarOrderEntry: Codable, Equatable {
    var data: SidebarOrderData
    var updatedAt: Int64
}

/// A group resolved against live sessions, in render order.
/// Empty groups are included so their headers stay droppable.
struct ResolvedSidebarGroup: Identifiable, Equatable {
    let name: String
    let isCollapsed: Bool
    let sessions: [ClaudeSession]
    var id: String { name }
}

/// Result of reconciling stored order data with the live session list.
struct SidebarResolution: Equatable {
    let data: SidebarOrderData
    let groups: [ResolvedSidebarGroup]
    let ungrouped: [ClaudeSession]
    let changed: Bool
}

enum SidebarOrder {
    static let storageKey = "allmyagents-session-groups"
    static let updatedAtKey = "allmyagents-session-groups-updated-at"

    // MARK: - Keys

    /// `host::name` with a nil/empty host normalized to "local".
    static func sessionKey(host: String?, name: String) -> String {
        let h = (host?.isEmpty ?? true) ? "local" : host!
        return "\(h)::\(name)"
    }

    /// Everything after the FIRST "::" (bare keys pass through),
    /// matching the web app's `split("::").slice(1).join("::")`.
    static func nameOfKey(_ key: String) -> String {
        guard let range = key.range(of: "::") else { return key }
        return String(key[range.upperBound...])
    }

    // MARK: - Persistence (with legacy migration)

    /// Loads persisted data. New format is detected by a top-level `groups`
    /// object; anything else shaped like `{ name: [keys] }` is the app's
    /// legacy format (no order/collapsed/ungroupedOrder) and migrates to
    /// alphabetical group order.
    static func load(from defaults: UserDefaults = .standard) -> SidebarOrderData {
        guard let data = defaults.data(forKey: storageKey),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty()
        }

        if obj["groups"] is [String: Any] {
            // A group name that collides with Object.prototype cannot be stored
            // as a plain object key, so it is dropped on the way in — the same
            // normalising the web app's sanitizeSidebarOrder does.
            return SidebarOrderData(
                groups: (obj["groups"] as? [String: [String]] ?? [:])
                    .filter { isSafeGroupName($0.key) },
                collapsed: (obj["collapsed"] as? [String: Bool] ?? [:])
                    .filter { isSafeGroupName($0.key) },
                order: (obj["order"] as? [String] ?? []).filter { isSafeGroupName($0) },
                ungroupedOrder: obj["ungroupedOrder"] as? [String] ?? []
            )
        }

        // Legacy: top-level { groupName: [sessionName, ...] }
        var groups: [String: [String]] = [:]
        for (name, value) in obj {
            if let members = value as? [String] {
                groups[name] = members
            }
        }
        return SidebarOrderData(
            groups: groups,
            collapsed: [:],
            order: groups.keys.sorted(),
            ungroupedOrder: []
        )
    }

    static func save(_ data: SidebarOrderData, to defaults: UserDefaults = .standard) {
        save(data, updatedAt: nowMillis(), to: defaults)
    }

    /// Persist a reconciled copy without claiming authorship of it: the
    /// timestamp stays where the last user edit left it. A reconcile only
    /// reshuffles keys against the live session list, so it must not make the
    /// copy look newer than the server's.
    static func saveReconciled(_ data: SidebarOrderData, to defaults: UserDefaults = .standard) {
        save(data, updatedAt: loadUpdatedAt(from: defaults), to: defaults)
    }

    /// Persist a copy while keeping the given timestamp — used when adopting the
    /// server's copy, which must not look like a fresh local edit.
    static func save(
        _ data: SidebarOrderData,
        updatedAt: Int64,
        to defaults: UserDefaults = .standard
    ) {
        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: storageKey)
        }
        defaults.set(Double(updatedAt), forKey: updatedAtKey)
    }

    /// Milliseconds since epoch when the local copy was last written (0 = never).
    static func loadUpdatedAt(from defaults: UserDefaults = .standard) -> Int64 {
        Int64(defaults.double(forKey: updatedAtKey))
    }

    /// The local copy as a sync entry (data + timestamp).
    static func entry(from defaults: UserDefaults = .standard) -> SidebarOrderEntry {
        SidebarOrderEntry(data: load(from: defaults), updatedAt: loadUpdatedAt(from: defaults))
    }

    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Merge resolution (mirrors web public/sidebar-sync.js)
    //
    // Group definitions are the user's work, not app state: a copy with no
    // groups can never erase a copy that has them. Both surfaces resolve with
    // this rule so a blank copy cannot win the race against a grouped one.
    // ADR 0017 amends ADR 0006: membership is server-declared — a session
    // carries the group it belongs to — so what this rule protects is the
    // group list and its order, and the `groupsCleared` erasure flag is gone
    // with the membership it described. See docs/adr/0006-groups-are-protected.md.

    /// Effective sync weight: the explicit timestamp when present, else 1 for a
    /// legacy copy that has content, else 0.
    static func entryTimestamp(_ entry: SidebarOrderEntry?) -> Int64 {
        guard let entry else { return 0 }
        if entry.updatedAt > 0 { return entry.updatedAt }
        let d = entry.data
        let hasContent = !d.groups.isEmpty || !d.order.isEmpty || !d.ungroupedOrder.isEmpty
        return hasContent ? 1 : 0
    }

    /// Does this copy define any groups?
    static func hasGroups(_ data: SidebarOrderData?) -> Bool {
        guard let data else { return false }
        return !data.groups.isEmpty
    }

    /// Which side of a merge wins.
    enum Winner: String {
        case local, remote, none
    }

    /// Resolve two copies of the sidebar order into one.
    ///
    /// Last-writer-wins by `updatedAt`, with one exception: a copy with no
    /// groups never erases a copy that has them.
    static func pickWinner(local: SidebarOrderEntry?, remote: SidebarOrderEntry?) -> Winner {
        let localTs = entryTimestamp(local)
        let remoteTs = entryTimestamp(remote)
        if hasGroups(remote?.data) && !hasGroups(local?.data) {
            return .remote
        }
        if hasGroups(local?.data) && !hasGroups(remote?.data) {
            return .local
        }
        if remoteTs > localTs { return .remote }
        if localTs > remoteTs { return .local }
        return localTs > 0 ? .local : .none
    }

    /// A group name that collides with `Object.prototype` cannot be stored as a
    /// plain object key: assigning it changes the object's prototype instead of
    /// adding a key, so the group silently disappears. Such a name is refused
    /// wherever a group name becomes an object key, on both sides, so they
    /// agree on what a group is.
    static func isSafeGroupName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name != "__proto__" && name != "constructor" && name != "prototype"
    }

    // MARK: - Pure mutations

    /// Move a session key to `target` (group name, or nil for the ungrouped
    /// region) at position `index` (post-removal insertion position).
    static func moveSession(
        _ data: SidebarOrderData,
        key: String,
        target: String?,
        index: Int
    ) -> SidebarOrderData {
        var next = data
        for name in Array(next.groups.keys) {
            next.groups[name] = (next.groups[name] ?? []).filter { $0 != key }
        }
        next.ungroupedOrder = next.ungroupedOrder.filter { $0 != key }

        if let target {
            // A name that cannot be stored as an object key is not a group: the
            // session lands in the ungrouped region instead of vanishing.
            guard isSafeGroupName(target) else {
                next.ungroupedOrder.insert(key, at: clamp(index, count: next.ungroupedOrder.count))
                return next
            }
            if next.groups[target] == nil {
                next.groups[target] = []
                if !next.order.contains(target) { next.order.append(target) }
            }
            let members = next.groups[target] ?? []
            var updated = members
            updated.insert(key, at: clamp(index, count: members.count))
            next.groups[target] = updated
        } else {
            next.ungroupedOrder.insert(key, at: clamp(index, count: next.ungroupedOrder.count))
        }
        return next
    }

    /// Delete a group. Its members' keys vanish, so resolve re-seeds them at
    /// the top of the ungrouped region (web deleteGroup behavior).
    static func deletingGroup(_ data: SidebarOrderData, name: String) -> SidebarOrderData {
        var next = data
        next.groups[name] = nil
        next.collapsed[name] = nil
        next.order = next.order.filter { $0 != name }
        return next
    }

    /// Reorder a group among its peers (post-removal insertion position).
    static func moveGroup(_ data: SidebarOrderData, name: String, index: Int) -> SidebarOrderData {
        var next = data
        next.order = next.order.filter { $0 != name }
        for groupName in next.groups.keys.sorted()
        where groupName != name && !next.order.contains(groupName) {
            next.order.append(groupName)
        }
        next.order.insert(name, at: clamp(index, count: next.order.count))
        return next
    }

    // MARK: - Resolution

    /// Reconcile stored keys against the live sessions and build the render view.
    ///
    /// - stored keys whose session is absent are kept (slot reserved)
    /// - a stored key whose session reappears under a different machine host
    ///   is rewritten to the new key, keeping its slot
    /// - sessions never seen before are seeded at the top of the ungrouped region
    /// - group names missing from `order` are appended
    static func resolve(data: SidebarOrderData, sessions: [ClaudeSession]) -> SidebarResolution {
        var next = data

        var keyToSession: [String: ClaudeSession] = [:]
        var nameToSession: [String: ClaudeSession] = [:]
        for session in sessions {
            if keyToSession[session.sidebarKey] == nil {
                keyToSession[session.sidebarKey] = session
            }
            if nameToSession[session.sidebarName] == nil {
                nameToSession[session.sidebarName] = session
            }
        }

        var changed = false

        func reconcileKey(_ storedKey: String) -> String {
            if keyToSession[storedKey] != nil { return storedKey }
            guard let match = nameToSession[nameOfKey(storedKey)] else { return storedKey }
            let newKey = match.sidebarKey
            if newKey != storedKey { changed = true }
            return newKey
        }

        var seen = Set<String>()

        for name in Array(next.groups.keys) {
            let stored = next.groups[name] ?? []
            var resolved: [String] = []
            for key in stored {
                let resolvedKey = reconcileKey(key)
                if seen.contains(resolvedKey) {
                    changed = true
                    continue
                }
                seen.insert(resolvedKey)
                resolved.append(resolvedKey)
            }
            if resolved.count != stored.count { changed = true }
            next.groups[name] = resolved
        }

        var ungroupedResolved: [String] = []
        for key in next.ungroupedOrder {
            let resolvedKey = reconcileKey(key)
            if seen.contains(resolvedKey) {
                changed = true
                continue
            }
            seen.insert(resolvedKey)
            ungroupedResolved.append(resolvedKey)
        }
        if ungroupedResolved.count != next.ungroupedOrder.count { changed = true }
        next.ungroupedOrder = ungroupedResolved

        var fresh: [String] = []
        for session in sessions where !seen.contains(session.sidebarKey) {
            seen.insert(session.sidebarKey)
            fresh.append(session.sidebarKey)
        }
        if !fresh.isEmpty {
            next.ungroupedOrder = fresh + next.ungroupedOrder
            changed = true
        }

        for groupName in Array(next.groups.keys) where !next.order.contains(groupName) {
            next.order.append(groupName)
            changed = true
        }

        // Render groups in persisted order; empty groups still render
        // ("groups[name] ?? []") so their headers stay droppable.
        let groups = next.order.map { name in
            ResolvedSidebarGroup(
                name: name,
                isCollapsed: next.collapsed[name] ?? false,
                sessions: (next.groups[name] ?? []).compactMap { keyToSession[$0] }
            )
        }
        let ungrouped = next.ungroupedOrder.compactMap { keyToSession[$0] }

        return SidebarResolution(data: next, groups: groups, ungrouped: ungrouped, changed: changed)
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), count)
    }
}

extension ClaudeSession {
    /// Name used for sidebar grouping — matches the legacy plain-name keys.
    var sidebarName: String {
        tmuxSession ?? displayName
    }

    /// Canonical session key (`host::name`) used in the order data.
    var sidebarKey: String {
        SidebarOrder.sessionKey(host: machineHost, name: sidebarName)
    }
}
