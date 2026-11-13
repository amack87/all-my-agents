import Foundation
import Testing
@testable import AllMyAgents

/// The macOS app talks to the web server over two transports: an HTTP poll of
/// `/api/mesh/sessions` and the `/ws/status` feed. Both must turn the server's
/// payload into the same sessions, or the app shows different things depending
/// on which transport happened to be live.
@Suite("Status feed client")
struct StatusFeedClientTests {

    @Test("the feed URL is the websocket form of the server URL")
    func feedURL() {
        #expect(StatusFeedClient.feedURL(serverURL: "http://localhost:3456")?.absoluteString == "ws://localhost:3456/ws/status")
        #expect(StatusFeedClient.feedURL(serverURL: "https://agents.example.com")?.absoluteString == "wss://agents.example.com/ws/status")
        #expect(StatusFeedClient.feedURL(serverURL: "http://192.168.1.4:3456")?.absoluteString == "ws://192.168.1.4:3456/ws/status")
    }

    @Test("a server URL without a scheme has no feed URL")
    func feedURLWithoutScheme() {
        #expect(StatusFeedClient.feedURL(serverURL: "localhost:3456") == nil)
    }

    @Test("a pushed snapshot decodes into the app's sessions")
    func decodeSnapshot() throws {
        let payload = """
        {"type":"sessions","peerStatus":{},"sessions":[
          {"name":"alpha","paneId":"%1","tty":"/dev/ttys001","currentCommand":"claude","windowName":"claude",
           "status":"needsInput","source":"event","agent":"Claude Code","projectPath":"/tmp/alpha",
           "summary":"a summary","lastActivity":1794595437,"machine":"andys-macbook-pro","machineHost":"local"}
        ]}
        """
        let sessions = try #require(StatusFeedClient.decodeSnapshot(Data(payload.utf8)))
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.tmuxSession == "alpha")
        #expect(session.tmuxPane == "%1")
        #expect(session.agent == "Claude Code")
        #expect(session.status == .needsInput)
        #expect(session.machineHost == "local")
        #expect(session.id == "mesh-local-alpha")
        #expect(session.lastActivity == Date(timeIntervalSince1970: 1794595437))
    }

    @Test("a pushed snapshot carries the same statuses as the HTTP payload")
    func decodeSnapshotStatuses() throws {
        let payload = """
        {"type":"sessions","sessions":[
          {"name":"a","status":"working"},
          {"name":"b","status":"ended"},
          {"name":"c","status":"idle"},
          {"name":"d","status":"unknown"},
          {"name":"e","status":"banana"}
        ]}
        """
        let sessions = try #require(StatusFeedClient.decodeSnapshot(Data(payload.utf8)))
        #expect(sessions.map(\.status) == [.working, .ended, .idle, .unknown, .unknown])
    }

    @Test("a malformed payload decodes to nothing rather than to empty sessions")
    func decodeMalformed() {
        #expect(StatusFeedClient.decodeSnapshot(Data("not json".utf8)) == nil)
        #expect(StatusFeedClient.decodeSnapshot(Data("{}".utf8)) == nil)
        #expect(StatusFeedClient.decodeSnapshot(Data("{\"type\":\"sessions\"}".utf8)) == nil)
    }

    @Test("the HTTP payload maps onto the same sessions as the pushed snapshot")
    func httpAndFeedAgree() throws {
        let mesh = MeshAPIClient.MeshSession(
            name: "alpha",
            paneId: "%1",
            status: "ended",
            agent: "Claude Code",
            projectPath: "/tmp/alpha",
            summary: "a summary",
            lastActivity: 1794595437,
            machine: "andys-macbook-pro",
            machineHost: "local"
        )
        let fromHTTP = MeshAPIClient.mapSessions([mesh])
        let payload = """
        {"type":"sessions","sessions":[
          {"name":"alpha","paneId":"%1","status":"ended","agent":"Claude Code","projectPath":"/tmp/alpha",
           "summary":"a summary","lastActivity":1794595437,"machine":"andys-macbook-pro","machineHost":"local"}
        ]}
        """
        let fromFeed = try #require(StatusFeedClient.decodeSnapshot(Data(payload.utf8)))
        #expect(fromHTTP.count == fromFeed.count)
        let http = try #require(fromHTTP.first)
        let feed = try #require(fromFeed.first)
        #expect(http.id == feed.id)
        #expect(http.tmuxSession == feed.tmuxSession)
        #expect(http.tmuxPane == feed.tmuxPane)
        #expect(http.status == feed.status)
        #expect(http.agent == feed.agent)
        #expect(http.projectPath == feed.projectPath)
        #expect(http.summary == feed.summary)
        #expect(http.machine == feed.machine)
        #expect(http.machineHost == feed.machineHost)
        #expect(http.lastActivity == feed.lastActivity)
    }

    @Test("a session without a machine host still gets a unique id")
    func localSessionID() {
        let mesh = MeshAPIClient.MeshSession(
            name: "alpha",
            paneId: nil,
            status: "idle",
            agent: nil,
            projectPath: nil,
            summary: nil,
            lastActivity: nil,
            machine: nil,
            machineHost: nil
        )
        let sessions = MeshAPIClient.mapSessions([mesh])
        #expect(sessions.first?.id == "mesh-local-alpha")
        #expect(sessions.first?.agent == "shell")
        #expect(sessions.first?.lastActivity == nil)
    }
}
