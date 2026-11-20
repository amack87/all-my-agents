import Foundation
import Testing
@testable import AllMyAgents

/// The shared contract fixture, read from `contract/sidebar-groups.json` at the
/// repo root. The web app's `web/test/contract.test.js` reads the same file.
///
/// This is the anti-drift mechanism: the groups-protected merge rule was
/// hand-ported from the web app into this one, and the hand-port quietly
/// disagreed with the original — a blank copy could erase a grouped one. The
/// rule now lives in one file of cases that both sides must satisfy, so the
/// next change breaks a test on the side that was not updated.
private struct SidebarGroupsContract: Decodable {
    struct WinnerCase: Decodable {
        let name: String
        let local: SidebarOrderEntry
        let remote: SidebarOrderEntry
        let expected: String
    }

    struct FlagCase: Decodable {
        let name: String
        let data: SidebarOrderData
        let hasGroups: Bool
    }

    let winnerCases: [WinnerCase]
    let flagCases: [FlagCase]
    let safeGroupNames: [String]
    let unsafeGroupNames: [String]
}

private enum ContractFixture {
    /// The repo root, from this file's path: <root>/Tests/AllMyAgentsTests/<file>.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let url = repoRoot.appendingPathComponent("contract/sidebar-groups.json")

    static func load() throws -> SidebarGroupsContract {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SidebarGroupsContract.self, from: data)
    }
}

@Test func contractFixtureIsPresent() throws {
    #expect(FileManager.default.fileExists(atPath: ContractFixture.url.path))
}

@Test func sidebarGroupsContractResolvesIdenticallyToTheWebApp() throws {
    let contract = try ContractFixture.load()
    #expect(!contract.winnerCases.isEmpty)

    for testCase in contract.winnerCases {
        let winner = SidebarOrder.pickWinner(local: testCase.local, remote: testCase.remote)
        #expect(
            winner.rawValue == testCase.expected,
            "contract case \"\(testCase.name)\": expected \(testCase.expected), got \(winner.rawValue)"
        )
    }
}

@Test func sidebarGroupsContractFlagsAgree() throws {
    let contract = try ContractFixture.load()
    #expect(!contract.flagCases.isEmpty)

    for testCase in contract.flagCases {
        #expect(
            SidebarOrder.hasGroups(testCase.data) == testCase.hasGroups,
            "contract case \"\(testCase.name)\": hasGroups disagreed"
        )
    }
}

@Test func sidebarGroupsContractGroupNamesAgree() throws {
    let contract = try ContractFixture.load()

    for name in contract.safeGroupNames {
        #expect(SidebarOrder.isSafeGroupName(name), "\"\(name)\" should be a safe group name")
    }
    for name in contract.unsafeGroupNames {
        #expect(!SidebarOrder.isSafeGroupName(name), "\"\(name)\" should be refused as a group name")
    }
}

// MARK: - The fields a session carries

/// The session-fields fixture, read from `contract/session-fields.json`.
/// Each case is a published session payload; this app's session decoder must
/// resolve its group and directory exactly as the case expects, the same way
/// the web app's shape check does.
private struct SessionFieldsContract: Decodable {
    struct Case: Decodable {
        let name: String
        let shape: String
        let session: MeshAPIClient.MeshSession
        let expected: Expected

        struct Expected: Decodable {
            let group: String?
            let dir: String?
        }
    }

    let cases: [Case]
}

@Test func sessionFieldsFixtureIsPresent() throws {
    let url = ContractFixture.repoRoot.appendingPathComponent("contract/session-fields.json")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func sessionFieldsContractResolvesIdenticallyToTheWebApp() throws {
    let url = ContractFixture.repoRoot.appendingPathComponent("contract/session-fields.json")
    let data = try Data(contentsOf: url)
    let contract = try JSONDecoder().decode(SessionFieldsContract.self, from: data)
    #expect(!contract.cases.isEmpty)

    for testCase in contract.cases {
        let sessions = MeshAPIClient.mapSessions([testCase.session])
        let session = try #require(sessions.first)
        #expect(
            session.group == testCase.expected.group,
            "contract case \"\(testCase.name)\": expected group \(testCase.expected.group ?? "nil"), got \(session.group ?? "nil")"
        )
        #expect(
            session.dir == testCase.expected.dir,
            "contract case \"\(testCase.name)\": expected dir \(testCase.expected.dir ?? "nil"), got \(session.dir ?? "nil")"
        )
    }
}

// MARK: - The membership merge

/// The membership fixture, read from `contract/sidebar-membership.json`.
/// Each case is a sidebar-order store plus a session list; this app's
/// `SidebarOrder.resolve` and the web app's `resolveOrder` must produce the
/// same groups, in the same order, with the same members.
private struct MembershipContract: Decodable {
    struct Case: Decodable {
        struct FixtureSession: Decodable {
            let key: String
            let name: String
            let group: String?
        }

        struct Expected: Decodable {
            struct Group: Decodable, Equatable {
                let name: String
                let serverDeclared: Bool
                let members: [String]
            }

            let groups: [Group]
            let ungrouped: [String]
        }

        let name: String
        let data: SidebarOrderData
        let sessions: [FixtureSession]
        let expected: Expected
    }

    let cases: [Case]
}

@Test func membershipFixtureIsPresent() throws {
    let url = ContractFixture.repoRoot.appendingPathComponent("contract/sidebar-membership.json")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func membershipContractResolvesIdenticallyToTheWebApp() throws {
    let url = ContractFixture.repoRoot.appendingPathComponent("contract/sidebar-membership.json")
    let data = try Data(contentsOf: url)
    let contract = try JSONDecoder().decode(MembershipContract.self, from: data)
    #expect(!contract.cases.isEmpty)

    for testCase in contract.cases {
        let sessions = testCase.sessions.map { fixture in
            // The fixture key is `host::name`; rebuilding the session from its
            // parts must reproduce exactly that key.
            let host = String(fixture.key.prefix(while: { $0 != ":" }))
            return ClaudeSession(
                id: fixture.key,
                pid: 0,
                tty: "",
                sessionUUID: nil,
                tmuxPane: nil,
                tmuxSession: fixture.name,
                projectPath: nil,
                summary: nil,
                agent: "shell",
                status: .idle,
                lastSeen: Date(),
                lastActivity: nil,
                machine: host == "local" ? nil : host,
                machineHost: host,
                task: nil,
                group: fixture.group,
                dir: nil
            )
        }
        let out = SidebarOrder.resolve(data: testCase.data, sessions: sessions)
        let observed = MembershipContract.Case.Expected(
            groups: out.groups.map { group in
                .init(
                    name: group.name,
                    serverDeclared: group.isServerDeclared,
                    members: group.sessions.map(\.sidebarName)
                )
            },
            ungrouped: out.ungrouped.map(\.sidebarName)
        )
        #expect(
            observed.groups == testCase.expected.groups,
            "contract case \"\(testCase.name)\": groups disagreed\n got \(observed.groups)\n expected \(testCase.expected.groups)"
        )
        #expect(
            observed.ungrouped == testCase.expected.ungrouped,
            "contract case \"\(testCase.name)\": ungrouped disagreed"
        )
    }
}
