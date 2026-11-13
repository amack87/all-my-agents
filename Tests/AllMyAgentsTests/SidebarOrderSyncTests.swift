import Testing
@testable import AllMyAgents

// The canonical cases from the web repo's test/sidebar-sync.test.js.
// Both surfaces must resolve a merge the same way, so the rules are pinned
// here and in the web repo. See the web repo's docs/adr/0006-groups-are-protected.md.

// MARK: - Fixtures

private func emptyData() -> SidebarOrderData { .empty() }

private func filledData() -> SidebarOrderData {
    SidebarOrderData(
        groups: ["Work": ["local::a"]],
        collapsed: [:],
        order: ["Work"],
        ungroupedOrder: ["local::b"]
    )
}

private func clearedData() -> SidebarOrderData {
    var data = SidebarOrderData.empty()
    data.groupsCleared = true
    return data
}

// MARK: - The groups-are-protected rule

@Test func `a copy with groups is not erased by a newer copy without them`() {
    let local = SidebarOrderEntry(data: filledData(), updatedAt: 100)
    let remote = SidebarOrderEntry(data: emptyData(), updatedAt: 200)

    #expect(SidebarOrder.pickWinner(local: local, remote: remote) == .local)
    #expect(SidebarOrder.pickWinner(local: remote, remote: local) == .remote)
}

@Test func `when both copies have groups, the newer one wins`() {
    let older = SidebarOrderEntry(data: filledData(), updatedAt: 100)
    let newer = SidebarOrderEntry(data: filledData(), updatedAt: 200)

    #expect(SidebarOrder.pickWinner(local: older, remote: newer) == .remote)
    #expect(SidebarOrder.pickWinner(local: newer, remote: older) == .local)
}

@Test func `a blank copy never erases the server's groups`() {
    let blank = SidebarOrderEntry(data: emptyData(), updatedAt: 0)
    let grouped = SidebarOrderEntry(data: filledData(), updatedAt: 1000)

    #expect(SidebarOrder.pickWinner(local: blank, remote: grouped) == .remote)
}

@Test func `a copy that declares it cleared its groups may replace one that has them`() {
    let cleared = SidebarOrderEntry(data: clearedData(), updatedAt: 200)
    let grouped = SidebarOrderEntry(data: filledData(), updatedAt: 100)

    #expect(SidebarOrder.pickWinner(local: cleared, remote: grouped) == .local)
}

// MARK: - Helpers

@Test func `hasGroups reports whether a copy defines any group`() {
    #expect(SidebarOrder.hasGroups(filledData()))
    #expect(!SidebarOrder.hasGroups(emptyData()))
    #expect(!SidebarOrder.hasGroups(nil))
}

@Test func `clearedGroups reports a deliberate erasure of the last group`() {
    #expect(SidebarOrder.clearedGroups(clearedData()))
    #expect(!SidebarOrder.clearedGroups(emptyData()))
    #expect(!SidebarOrder.clearedGroups(nil))
}

@Test func `a legacy copy with content counts as timestamp 1, a blank one as 0`() {
    #expect(SidebarOrder.entryTimestamp(SidebarOrderEntry(data: filledData(), updatedAt: 0)) == 1)
    #expect(SidebarOrder.entryTimestamp(SidebarOrderEntry(data: emptyData(), updatedAt: 0)) == 0)
    #expect(SidebarOrder.entryTimestamp(nil) == 0)
}

@Test func `two blank copies have nothing to sync`() {
    let blank = SidebarOrderEntry(data: emptyData(), updatedAt: 0)
    #expect(SidebarOrder.pickWinner(local: blank, remote: blank) == .none)
    #expect(SidebarOrder.pickWinner(local: nil, remote: nil) == .none)
}

@Test func `unsafe group names are refused`() {
    #expect(SidebarOrder.isSafeGroupName("Work"))
    #expect(!SidebarOrder.isSafeGroupName(""))
    #expect(!SidebarOrder.isSafeGroupName("__proto__"))
    #expect(!SidebarOrder.isSafeGroupName("constructor"))
    #expect(!SidebarOrder.isSafeGroupName("prototype"))
}
