import Testing
import Foundation
@testable import AllMyAgents

// The group lifecycle plus the normalising the web app's
// sanitizeSidebarOrder does. The groupsCleared erasure flag these tests used
// to pin is gone with the client-owned membership it described (ADR 0017
// amends ADR 0006: membership is server-declared now). See
// docs/adr/0006-groups-are-protected.md.

private func makeDefaults() -> UserDefaults {
    let suite = "SidebarOrderTests." + UUID().uuidString
    return UserDefaults(suiteName: suite)!
}

private func twoGroupsData() -> SidebarOrderData {
    SidebarOrderData(
        groups: ["Work": ["local::a"], "Home": ["local::b"]],
        collapsed: [:],
        order: ["Work", "Home"],
        ungroupedOrder: []
    )
}

// MARK: - Normalising a stored copy

@Test func `an unsafe group name sends the session to the ungrouped region`() {
    let result = SidebarOrder.moveSession(.empty(), key: "local::a", target: "__proto__", index: 0)

    #expect(result.groups.isEmpty)
    #expect(result.order.isEmpty)
    #expect(result.ungroupedOrder == ["local::a"])
}

// MARK: - Reading a stored copy

@Test func `loading drops unsafe group names`() {
    let defaults = makeDefaults()
    let raw = """
    {"groups":{"__proto__":["local::a"],"Work":["local::b"]},\
    "collapsed":{"__proto__":true,"Work":false},\
    "order":["__proto__","Work"],"ungroupedOrder":["local::c"]}
    """
    defaults.set(raw.data(using: .utf8), forKey: SidebarOrder.storageKey)

    let data = SidebarOrder.load(from: defaults)

    #expect(data.groups == ["Work": ["local::b"]])
    #expect(data.collapsed == ["Work": false])
    #expect(data.order == ["Work"])
    #expect(data.ungroupedOrder == ["local::c"])
}

@Test func `a reconciled copy keeps the existing timestamp`() {
    let defaults = makeDefaults()
    SidebarOrder.save(.empty(), updatedAt: 1_700_000_000_000, to: defaults)

    // A reconcile reshuffles keys; it is not a user edit, so the timestamp
    // must not move and the copy must not outrank the server's.
    SidebarOrder.saveReconciled(
        SidebarOrderData(groups: [:], collapsed: [:], order: [], ungroupedOrder: ["local::a"]),
        to: defaults
    )

    #expect(SidebarOrder.loadUpdatedAt(from: defaults) == 1_700_000_000_000)
}

@Test func `a user edit does move the timestamp`() {
    let defaults = makeDefaults()
    SidebarOrder.save(.empty(), updatedAt: 1_700_000_000_000, to: defaults)

    SidebarOrder.save(
        SidebarOrderData(groups: [:], collapsed: [:], order: [], ungroupedOrder: ["local::a"]),
        to: defaults
    )

    #expect(SidebarOrder.loadUpdatedAt(from: defaults) > 1_700_000_000_000)
}

// MARK: - Server-declared membership (ADR 0017)

private func session(_ name: String, group: String?, host: String = "local") -> ClaudeSession {
    ClaudeSession(
        id: "\(host)::\(name)",
        pid: 0,
        tty: "",
        sessionUUID: nil,
        tmuxPane: nil,
        tmuxSession: name,
        projectPath: nil,
        summary: nil,
        agent: "shell",
        status: .idle,
        lastSeen: Date(),
        lastActivity: nil,
        machine: host == "local" ? nil : host,
        machineHost: host,
        task: nil,
        group: group,
        dir: nil
    )
}

@Test func `a session created in a group appears under that group and is adopted, not claimed`() {
    let out = SidebarOrder.resolve(
        data: .empty(),
        sessions: [session("alpha", group: "Task Factory"), session("beta", group: nil)]
    )

    #expect(out.groups.count == 1)
    #expect(out.groups[0].name == "Task Factory")
    #expect(out.groups[0].isServerDeclared == true)
    #expect(out.groups[0].sessions.map(\.sidebarName) == ["alpha"])
    #expect(out.ungrouped.map(\.sidebarName) == ["beta"])
    #expect(out.data.serverGroups == ["Task Factory"])
    #expect(out.data.order.isEmpty)
    #expect(out.changed)
}

@Test func `a new member is appended after the existing members`() {
    let data = SidebarOrderData(
        groups: ["Task Factory": ["local::one"]],
        order: [],
        ungroupedOrder: [],
        serverGroups: ["Task Factory"]
    )
    let out = SidebarOrder.resolve(
        data: data,
        sessions: [session("two", group: "Task Factory"), session("one", group: "Task Factory")]
    )

    #expect(out.groups[0].sessions.map(\.sidebarName) == ["one", "two"])
}

@Test func `a live session with no declared group is not held by a stored group`() {
    let data = SidebarOrderData(groups: ["A": ["local::x"]], order: ["A"])
    let out = SidebarOrder.resolve(data: data, sessions: [session("x", group: nil)])

    #expect(out.groups[0].sessions.isEmpty)
    #expect(out.ungrouped.map(\.sidebarName) == ["x"])
    #expect(out.data.groups["A"] == [])
    #expect(out.data.ungroupedOrder == ["local::x"])
}

@Test func `acting on a group claims it out of the adoption record`() {
    let claimed = SidebarOrder.moveSession(.empty(), key: "local::alpha", target: "Task Factory", index: 0)

    #expect(claimed.order == ["Task Factory"])
    #expect(claimed.serverGroups.isEmpty)

    let out = SidebarOrder.resolve(
        data: claimed,
        sessions: [session("alpha", group: "Task Factory")]
    )
    #expect(out.groups[0].isServerDeclared == false)
}

@Test func `reordering a group claims it too`() {
    let data = SidebarOrderData(groups: ["Task Factory": []], serverGroups: ["Task Factory"])
    let claimed = SidebarOrder.moveGroup(data, name: "Task Factory", index: 0)

    #expect(claimed.order == ["Task Factory"])
    #expect(claimed.serverGroups.isEmpty)
}

@Test func `a server-declared group whose members are all gone leaves no residue`() {
    let seeded = SidebarOrder.resolve(
        data: .empty(),
        sessions: [session("alpha", group: "Task Factory")]
    )
    #expect(seeded.data.serverGroups == ["Task Factory"])

    let out = SidebarOrder.resolve(data: seeded.data, sessions: [])

    #expect(out.data.serverGroups.isEmpty)
    #expect(out.data.groups.isEmpty)
    #expect(out.groups.isEmpty)
}
