import Foundation

/// A peer machine the server knows about (`GET /api/identity`).
struct ServerIdentity: Decodable, Equatable {
    struct Peer: Decodable, Equatable {
        let name: String?
        let host: String
        let port: Int?
    }

    let name: String?
    let peers: [Peer]
}

/// A remote machine a session can reach through a launch command
/// (`GET /api/targets`).
struct ServerTarget: Decodable, Equatable {
    let name: String
    let label: String?
}

/// Where a new session should be created.
enum SessionDestination: Hashable {
    /// This machine — `POST /api/sessions`.
    case local
    /// A mesh peer — `POST /api/proxy/<host>/sessions`.
    case peer(host: String)
    /// A launch-command target — `POST /api/sessions` with a `target`.
    case target(name: String)
}

/// The request the web client makes for a destination.
enum SessionRequest: Equatable {
    case local(name: String)
    case peer(name: String, host: String)
    case target(name: String, target: String)
}

/// One entry in the machine picker.
struct MachineOption: Identifiable, Equatable {
    let destination: SessionDestination
    let label: String

    /// The value the web client would put in the `<select>`.
    var id: String {
        switch destination {
        case .local: "local"
        case .peer(let host): host
        case .target(let name): "target:\(name)"
        }
    }
}

/// The pure half of session creation: which machines can host a new session,
/// and which request each one implies. Mirrors the web app's
/// `populateMachinePicker()` and `createSession()` in `public/app.js`.
enum SessionCreation {
    /// The machines offered when creating a session, in the web app's order:
    /// this machine, then identity peers, then machines seen in the current
    /// sessions, then launch-command targets. Duplicates are dropped.
    static func options(
        identity: ServerIdentity?,
        targets: [ServerTarget],
        sessions: [ClaudeSession]
    ) -> [MachineOption] {
        var options: [MachineOption] = []
        var seen = Set(["local"])

        func append(label: String, destination: SessionDestination, value: String) {
            guard !seen.contains(value) else { return }
            seen.insert(value)
            options.append(MachineOption(destination: destination, label: label))
        }

        // This machine always leads the list.
        options.append(
            MachineOption(destination: .local, label: identity?.name ?? "This machine")
        )

        for peer in identity?.peers ?? [] {
            let port = peer.port ?? 3456
            let host = "\(peer.host):\(port)"
            append(
                label: peer.name ?? peer.host,
                destination: .peer(host: host),
                value: host
            )
        }

        for session in sessions {
            guard let host = session.machineHost, !host.isEmpty else { continue }
            append(
                label: session.machine ?? host,
                destination: .peer(host: host),
                value: host
            )
        }

        for target in targets {
            let value = "target:\(target.name)"
            append(
                label: target.label ?? target.name,
                destination: .target(name: target.name),
                value: value
            )
        }

        return options
    }

    /// The request the web client would make for this destination.
    static func request(for destination: SessionDestination, name: String) -> SessionRequest {
        switch destination {
        case .local:
            return .local(name: name)
        case .peer(let host):
            return .peer(name: name, host: host)
        case .target(let target):
            return .target(name: name, target: target)
        }
    }
}
