import Foundation
import Testing
@testable import AllMyAgents

/// The shared task fixture, read from `contract/task-update.json` at the repo
/// root. The web app's `web/test/task-contract.test.js` reads the same file.
///
/// A task is free text an agent reports about itself. The web server trims it
/// and caps its length; both apps carry it verbatim. The wire tasks below are
/// the shared subset: what the server hands over must reach the macOS app
/// unchanged, markup and all — escaping is the renderer's job, not the
/// decoder's.
private struct TaskUpdateContract: Decodable {
    struct Rules: Decodable {
        let maxLength: Int
        let trim: Bool
        let emptyIsNull: Bool
        let absentKeepsPrevious: Bool
    }

    let rules: Rules
    let wireTasks: [String]
}

private enum TaskFixture {
    /// The repo root, from this file's path: <root>/Tests/AllMyAgentsTests/<file>.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let url = repoRoot.appendingPathComponent("contract/task-update.json")

    static func load() throws -> TaskUpdateContract {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TaskUpdateContract.self, from: data)
    }
}

/// Decodes one mesh session carrying a task, the way the server sends it.
private func decodeMeshSession(task: String?) throws -> MeshAPIClient.MeshSession {
    var payload: [String: Any] = ["name": "s"]
    if let task { payload["task"] = task }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(MeshAPIClient.MeshSession.self, from: data)
}

@Test func taskContractFixtureIsPresent() throws {
    #expect(FileManager.default.fileExists(atPath: TaskFixture.url.path))
}

@Test func taskWireTasksSurviveTheMeshDecodeVerbatim() throws {
    let contract = try TaskFixture.load()
    #expect(!contract.wireTasks.isEmpty)

    for task in contract.wireTasks {
        let session = try decodeMeshSession(task: task)
        #expect(session.task == task, "the task must cross the wire unchanged: \(task)")
    }
}

@Test func taskReachesTheSessionModelUnchanged() throws {
    let contract = try TaskFixture.load()
    let task = try #require(contract.wireTasks.first)

    let sessions = MeshAPIClient.mapSessions([try decodeMeshSession(task: task)])
    let session = try #require(sessions.first)
    #expect(session.task == task)
}

@Test func aMeshSessionWithoutATaskDecodesWithNoTask() throws {
    let session = try decodeMeshSession(task: nil)
    #expect(session.task == nil)
}

@Test func everyWireTaskIsWithinTheStatedLength() throws {
    let contract = try TaskFixture.load()
    #expect(contract.rules.maxLength > 0)
    for task in contract.wireTasks {
        #expect(task.count <= contract.rules.maxLength, "the task is within the cap: \(task)")
    }
}
