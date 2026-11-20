import Foundation
import Testing
@testable import AllMyAgents

/// The machine picker and request routing, mirrored from the web app's
/// `populateMachinePicker()` / `createSession()` in `public/app.js`.
@Suite("Session creation")
struct SessionCreationTests {

    private func session(machine: String?, machineHost: String?) -> ClaudeSession {
        ClaudeSession(
            id: "s-\(machineHost ?? "local")",
            pid: 0,
            tty: "",
            sessionUUID: nil,
            tmuxPane: nil,
            tmuxSession: "sess",
            projectPath: nil,
            summary: nil,
            agent: "shell",
            status: .idle,
            lastSeen: Date(),
            lastActivity: nil,
            machine: machine,
            machineHost: machineHost,
            task: nil,
            group: nil,
            dir: nil,
            state: nil
        )
    }

    @Test("this machine is first, labelled with the identity name")
    func localIsFirst() {
        let options = SessionCreation.options(
            identity: ServerIdentity(name: "MBP M4", peers: []),
            targets: [],
            sessions: []
        )
        #expect(options.count == 1)
        #expect(options[0].destination == .local)
        #expect(options[0].label == "MBP M4")
    }

    @Test("without an identity the local machine is still offered")
    func localWithoutIdentity() {
        let options = SessionCreation.options(identity: nil, targets: [], sessions: [])
        #expect(options.count == 1)
        #expect(options[0].label == "This machine")
    }

    @Test("peers follow, addressed as host:port")
    func peersFollowLocal() {
        let identity = ServerIdentity(
            name: "MBP M4",
            peers: [
                .init(name: "Windows box", host: "100.1.2.3", port: 3456),
                .init(name: nil, host: "100.4.5.6", port: nil),
            ]
        )
        let options = SessionCreation.options(identity: identity, targets: [], sessions: [])
        #expect(options.count == 3)
        #expect(options[1].destination == .peer(host: "100.1.2.3:3456"))
        #expect(options[1].label == "Windows box")
        #expect(options[2].destination == .peer(host: "100.4.5.6:3456"))
        #expect(options[2].label == "100.4.5.6")
    }

    @Test("machines seen in sessions follow the peers")
    func sessionMachinesFollowPeers() {
        let identity = ServerIdentity(
            name: "MBP M4",
            peers: [.init(name: "Windows box", host: "100.1.2.3", port: 3456)]
        )
        let sessions = [session(machine: "iMac", machineHost: "100.9.9.9:3456")]
        let options = SessionCreation.options(identity: identity, targets: [], sessions: sessions)
        #expect(options.count == 3)
        #expect(options[2].destination == .peer(host: "100.9.9.9:3456"))
        #expect(options[2].label == "iMac")
    }

    @Test("a machine already listed is not repeated")
    func noDuplicates() {
        let identity = ServerIdentity(
            name: "MBP M4",
            peers: [.init(name: "Windows box", host: "100.1.2.3", port: 3456)]
        )
        let sessions = [
            session(machine: "Windows box", machineHost: "100.1.2.3:3456"),
            session(machine: nil, machineHost: "local"),
        ]
        let options = SessionCreation.options(identity: identity, targets: [], sessions: sessions)
        #expect(options.count == 2)
        #expect(options.map(\.id) == ["local", "100.1.2.3:3456"])
    }

    @Test("targets come last and are namespaced apart from peer hosts")
    func targetsAreNamespaced() {
        let identity = ServerIdentity(
            name: "MBP M4",
            peers: [.init(name: "Windows box", host: "100.1.2.3", port: 3456)]
        )
        let targets = [
            ServerTarget(name: "winbox", label: "Windows box (SSH)"),
            ServerTarget(name: "plain", label: nil),
        ]
        let options = SessionCreation.options(identity: identity, targets: targets, sessions: [])
        #expect(options.count == 4)
        #expect(options[2].destination == .target(name: "winbox"))
        #expect(options[2].id == "target:winbox")
        #expect(options[2].label == "Windows box (SSH)")
        #expect(options[3].destination == .target(name: "plain"))
        #expect(options[3].label == "plain")
    }

    @Test("each destination maps to the request the web client makes")
    func requestRouting() {
        #expect(
            SessionCreation.request(for: .local, name: "work")
                == .local(name: "work")
        )
        #expect(
            SessionCreation.request(for: .peer(host: "100.1.2.3:3456"), name: "work")
                == .peer(name: "work", host: "100.1.2.3:3456")
        )
        #expect(
            SessionCreation.request(for: .target(name: "winbox"), name: "work")
                == .target(name: "work", target: "winbox")
        )
    }
}
