import Foundation

// Pure ordering model for the sidebar (groups + ungrouped region).
// Direct port of the web app's public/session-order.js so both apps share
// one persisted format and identical semantics:
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
// nothing here reads a session's status, so tiles never move themselves (see
// the web repo's docs/adr/0001-manual-sidebar-order.md).

/// Persisted sidebar order structure — exactly the web app's JSON shape.
struct SidebarOrderData: Codable, Equatable {
    var groups: [String: [String]]
    var collapsed: [String: Bool]
    var order: [String]
    var ungroupedOrder: [String]
    /// Group names adopted from the sessions' server-declared membership
    /// rather than claimed by James (ADR 0017). A name in `order` is his.
    var serverGroups: [String]

    init(
        groups: [String: [String]] = [:],
        collapsed: [String: Bool] = [:],
        order: [String] = [],
        ungroupedOrder: [String] = [],
        serverGroups: [String] = []
    ) {
        self.groups = groups
        self.collapsed = collapsed
        self.order = order
        self.ungroupedOrder = ungroupedOrder
        self.serverGroups = serverGroups
    }

    private enum CodingKeys: String, CodingKey {
        case groups, collapsed, order, ungroupedOrder, serverGroups
    }

    /// Older copies of the store predate `serverGroups`; a stored copy is
    /// decoded the same way regardless of which surface wrote it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([String: [String]].self, forKey: .groups) ?? [:]
        collapsed = try container.decodeIfPresent([String: Bool].self, forKey: .collapsed) ?? [:]
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        ungroupedOrder = try container.decodeIfPresent([String].self, forKey: .ungroupedOrder) ?? []
        serverGroups = try container.decodeIfPresent([String].self, forKey: .serverGroups) ?? []
    }

    static func empty() -> SidebarOrderData {
        SidebarOrderData()
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
    /// True when the group exists because sessions declare it (adopted from
    /// the server) rather than because James arranged it.
    let isServerDeclared: Bool
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
            // A group James has claimed lives in `order`, so an adopted name
            // that also appears there is not an adoption any more.
            let claimed = Set((obj["order"] as? [String] ?? []).filter { isSafeGroupName($0) })
            return SidebarOrderData(
                groups: (obj["groups"] as? [String: [String]] ?? [:])
                    .filter { isSafeGroupName($0.key) },
                collapsed: (obj["collapsed"] as? [String: Bool] ?? [:])
                    .filter { isSafeGroupName($0.key) },
                order: (obj["order"] as? [String] ?? []).filter { isSafeGroupName($0) },
                ungroupedOrder: obj["ungroupedOrder"] as? [String] ?? [],
                serverGroups: Array(Set(
                    (obj["serverGroups"] as? [String] ?? []).filter {
                        isSafeGroupName($0) && !claimed.contains($0)
                    }
                ))
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
            }
            // Acting on a group claims it: it moves out of the adoption record
            // into James's own group list, so the sidebar stops marking it
            // server-declared.
            next.serverGroups.removeAll { $0 == target }
            if !next.order.contains(target) { next.order.append(target) }
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
        // Reordering a group claims it, the same way acting on a session does.
        next.serverGroups.removeAll { $0 == name }
        next.order = next.order.filter { $0 != name }
        for groupName in next.groups.keys.sorted()
        where groupName != name && !next.order.contains(groupName) {
            next.order.append(groupName)
        }
        next.order.insert(name, at: clamp(index, count: next.order.count))
        return next
    }

    // MARK: - Resolution

    /// Reconcile stored keys against the live sessions and build the render view,
    /// merging the sessions' server-declared membership with the manual order.
    ///
    /// - stored keys whose session is absent are kept (slot reserved)
    /// - a stored key whose session reappears under a different machine host
    ///   is rewritten to the new key, keeping its slot
    /// - a session's declared group is where it renders: a member arriving
    ///   joins the END of its group's order, so the members already there
    ///   never shuffle
    /// - a declared group the store has never seen is adopted into
    ///   `serverGroups` and rendered after James's own groups
    /// - a live session that declares no group is re-homed to the ungrouped
    ///   region (membership used to be client-owned; the server is the
    ///   authority now)
    /// - a server-declared group whose members are all gone loses its
    ///   adoption — membership lives on the sessions, so it disappears with
    ///   them
    /// - group names stored before this resolve and missing from `order` are
    ///   appended (James's own groups never silently vanish)
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

        func declaredGroup(_ session: ClaudeSession) -> String? {
            guard let group = session.group, isSafeGroupName(group) else { return nil }
            return group
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

        // Membership merge. The stored keys were reconciled first, so this pass
        // re-homes live sessions by what the server declares, not by what a
        // stale copy of the store says.
        let storedGroupNames = Set(next.groups.keys)
        let storedUngrouped = Set(next.ungroupedOrder)
        var freshUngrouped: [String] = []

        for session in sessions {
            let k = session.sidebarKey
            if let declared = declaredGroup(session) {
                // Adopt a group name no copy of the store has arranged yet.
                if !next.order.contains(declared) && !next.serverGroups.contains(declared) {
                    next.serverGroups.append(declared)
                    changed = true
                }
                if next.groups[declared] == nil { next.groups[declared] = [] }
                // The session leaves every group it does not declare.
                for name in Array(next.groups.keys) where name != declared {
                    if let idx = next.groups[name]?.firstIndex(of: k) {
                        next.groups[name]?.remove(at: idx)
                        changed = true
                    }
                }
                // A member arriving appends after the existing members: their
                // order — James's — is left alone.
                if next.groups[declared]?.contains(k) != true {
                    next.groups[declared]?.append(k)
                    changed = true
                }
            } else {
                // No declaration: the tile belongs in the ungrouped region. It
                // must not be held by a group the store remembers from a
                // client-owned past.
                for name in Array(next.groups.keys) {
                    if let idx = next.groups[name]?.firstIndex(of: k) {
                        next.groups[name]?.remove(at: idx)
                        changed = true
                    }
                }
                if !storedUngrouped.contains(k) && !freshUngrouped.contains(k) {
                    freshUngrouped.append(k)
                }
            }
        }

        // Sessions whose declared home is the ungrouped region and that have no
        // stored ungrouped slot seed at the top, in session-list order.
        if !freshUngrouped.isEmpty {
            next.ungroupedOrder = freshUngrouped + next.ungroupedOrder
            changed = true
        }

        // Group names the store already arranged but that `order` lost are
        // still James's own: they rejoin the group list. Names adopted this
        // resolve are not claimed by it.
        for groupName in next.groups.keys.sorted() {
            if storedGroupNames.contains(groupName) || next.order.contains(groupName) {
                continue
            }
            if next.serverGroups.contains(groupName) { continue }
            next.order.append(groupName)
            changed = true
        }
        for groupName in storedGroupNames.sorted() {
            if !next.order.contains(groupName) && !next.serverGroups.contains(groupName) {
                next.order.append(groupName)
                changed = true
            }
        }

        // Membership lives on the sessions (ADR 0017): a server-declared group
        // whose members have all gone loses its adoption and leaves no
        // ordering residue.
        next.serverGroups = next.serverGroups.filter { name in
            if sessions.contains(where: { declaredGroup($0) == name }) { return true }
            next.groups[name] = nil
            changed = true
            return false
        }

        // Render James's groups in his order, then the adopted
        // (server-declared) ones in adoption order.
        func groupSessions(_ name: String) -> [ClaudeSession] {
            (next.groups[name] ?? []).compactMap { keyToSession[$0] }
                .filter { declaredGroup($0) == name }
        }
        let groups =
            next.order.map { name in
                ResolvedSidebarGroup(
                    name: name,
                    isCollapsed: next.collapsed[name] ?? false,
                    isServerDeclared: false,
                    sessions: groupSessions(name)
                )
            }
            + next.serverGroups
                .filter { !next.order.contains($0) }
                .map { name in
                    ResolvedSidebarGroup(
                        name: name,
                        isCollapsed: next.collapsed[name] ?? false,
                        isServerDeclared: true,
                        sessions: groupSessions(name)
                    )
                }
        let ungrouped = next.ungroupedOrder.compactMap { keyToSession[$0] }
            .filter { declaredGroup($0) == nil }

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
