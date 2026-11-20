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
