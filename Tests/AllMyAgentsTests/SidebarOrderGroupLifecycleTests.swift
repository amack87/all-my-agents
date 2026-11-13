import Testing
import Foundation
@testable import AllMyAgents

// The lifecycle of the `groupsCleared` flag — the one statement that lets a
// copy without groups replace one that has them — plus the normalising the
// web app's sanitizeSidebarOrder does. See the web repo's
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

// MARK: - The erasure flag

@Test func `deleting the last group records the erasure`() {
    let result = SidebarOrder.deletingGroup(twoGroupsData(), name: "Work")
    #expect(result.groups["Work"] == nil)
    #expect(result.groupsCleared != true)

    let last = SidebarOrder.deletingGroup(result, name: "Home")
    #expect(last.groups.isEmpty)
    #expect(last.groupsCleared == true)
}

@Test func `creating a group clears an earlier erasure`() {
    var data = SidebarOrderData.empty()
    data.groupsCleared = true

    let result = SidebarOrder.moveSession(data, key: "local::a", target: "Work", index: 0)

    #expect(result.groups["Work"] == ["local::a"])
    #expect(result.groupsCleared == nil)
}

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

@Test func `loading carries the erasure flag`() {
    let defaults = makeDefaults()
    let raw = """
    {"groups":{},"collapsed":{},"order":[],"ungroupedOrder":[],"groupsCleared":true}
    """
    defaults.set(raw.data(using: .utf8), forKey: SidebarOrder.storageKey)

    #expect(SidebarOrder.load(from: defaults).groupsCleared == true)
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
