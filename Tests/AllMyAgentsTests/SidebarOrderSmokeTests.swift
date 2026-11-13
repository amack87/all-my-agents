import Testing
@testable import AllMyAgents

/// Smoke test: the pure sidebar-order module is reachable from a test target.
@Test func emptyDataHasNoGroups() {
    #expect(SidebarOrderData.empty().groups.isEmpty)
}
