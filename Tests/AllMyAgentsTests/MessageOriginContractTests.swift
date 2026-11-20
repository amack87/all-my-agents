import Foundation
import Testing

/// The shared message-origin fixture, read from `contract/message-origin.json`
/// at the repo root. The web app's `web/test/message-origin.test.js` reads the
/// same file.
///
/// This is the anti-drift rule applied to the chat panel's record: where a
/// message came from is a fact both apps must agree on, so the cases live in
/// one fixture and each suite asserts it resolves identically. The macOS panel
/// is a later step; this suite carries what it will need — the wire shape of a
/// message, and the one rule that reads it.
private struct MessageOriginContract: Decodable {
    struct Case: Decodable {
        let name: String
        let message: Message
        let fromPanel: Bool

        /// A message as the server serves it on the message route. `origin` is
        /// optional: a server that predates the tag sends no origin at all.
        struct Message: Decodable {
            let id: Int
            let text: String
            let at: Double
            let origin: String?
        }
    }

    let panelOrigin: String
    let agentOrigin: String
    let cases: [Case]
}

private enum MessageOriginFixture {
    /// The repo root, from this file's path: <root>/Tests/AllMyAgentsTests/<file>.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let url = repoRoot.appendingPathComponent("contract/message-origin.json")

    static func load() throws -> MessageOriginContract {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MessageOriginContract.self, from: data)
    }
}

/// The one rule that reads an origin: a message is from the panel exactly when
/// its origin is the panel's origin. The fixture decides what that means.
private func isPanelMessage(_ message: MessageOriginContract.Case.Message,
                            panelOrigin: String) -> Bool {
    message.origin == panelOrigin
}

@Test func messageOriginFixtureIsPresent() throws {
    #expect(FileManager.default.fileExists(atPath: MessageOriginFixture.url.path))
}

@Test func messageOriginContractResolvesIdenticallyToTheWebApp() throws {
    let contract = try MessageOriginFixture.load()
    #expect(!contract.cases.isEmpty)

    for testCase in contract.cases {
        #expect(
            isPanelMessage(testCase.message, panelOrigin: contract.panelOrigin) == testCase.fromPanel,
            "contract case \"\(testCase.name)\": fromPanel disagreed"
        )
    }
}

@Test func messageOriginWordsMatchTheFixture() throws {
    let contract = try MessageOriginFixture.load()
    #expect(contract.panelOrigin == "panel", "the panel's origin is the panel")
    #expect(contract.agentOrigin == "agent", "the agent's own output is the agent")
}
