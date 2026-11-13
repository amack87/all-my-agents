import Foundation
import Testing
@testable import AllMyAgents

/// The shared status vocabulary, read from `contract/status-vocabulary.json` at
/// the repo root. The web app's `web/test/contract.test.js` reads the same file.
///
/// The web server speaks five statuses. The macOS app used to know four of
/// them: "ended" fell through to `.unknown` and rendered as "…" where the web
/// rendered "Ended". The vocabulary now lives in one file of cases that both
/// sides must satisfy.
private struct StatusVocabularyContract: Decodable {
    struct WireCase: Decodable {
        let name: String
        let wire: String?
        let expected: String
    }

    let statuses: [String]
    let labels: [String: [String: String]]
    let wireCases: [WireCase]
}

private enum StatusContractFixture {
    /// The repo root, from this file's path: <root>/Tests/AllMyAgentsTests/<file>.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let url = repoRoot.appendingPathComponent("contract/status-vocabulary.json")

    static func load() throws -> StatusVocabularyContract {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StatusVocabularyContract.self, from: data)
    }
}

@Test func statusVocabularyFixtureIsPresent() throws {
    #expect(FileManager.default.fileExists(atPath: StatusContractFixture.url.path))
}

@Test func statusVocabularyContractMapsIdenticallyToTheWebApp() throws {
    let contract = try StatusContractFixture.load()
    #expect(!contract.wireCases.isEmpty)

    for testCase in contract.wireCases {
        let status = ClaudeSession.SessionStatus(wire: testCase.wire)
        #expect(
            status.wireValue == testCase.expected,
            "contract case \"\(testCase.name)\": expected \(testCase.expected), got \(status.wireValue)"
        )
    }
}

@Test func statusVocabularyContractKnowsEveryStatusTheServerSpeaks() throws {
    let contract = try StatusContractFixture.load()
    #expect(!contract.statuses.isEmpty)

    let known = Set(contract.statuses)
    for status in ClaudeSession.SessionStatus.allCases {
        #expect(
            known.contains(status.wireValue),
            "the macOS app knows \"\(status.wireValue)\" but the server does not speak it"
        )
    }
    for wire in contract.statuses {
        #expect(
            ClaudeSession.SessionStatus.allCases.contains { $0.wireValue == wire },
            "the server speaks \"\(wire)\" but the macOS app does not know it"
        )
    }
}

@Test func statusVocabularyContractLabelsAgree() throws {
    let contract = try StatusContractFixture.load()
    let macosLabels = contract.labels["macos"] ?? [:]
    #expect(!macosLabels.isEmpty)

    for status in ClaudeSession.SessionStatus.allCases {
        let expected = macosLabels[status.wireValue]
        #expect(
            expected != nil,
            "the contract has no macOS label for \"\(status.wireValue)\""
        )
        #expect(
            status.label == expected,
            "label for \"\(status.wireValue)\": expected \(expected ?? "nil"), got \(status.label)"
        )
    }
}
