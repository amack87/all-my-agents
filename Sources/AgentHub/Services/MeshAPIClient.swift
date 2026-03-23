import Foundation

/// Fetches aggregated sessions from the All My Agents web server's mesh API.
/// Returns nil on any failure (server not running, timeout, decode error),
/// signaling the caller to fall back to local-only discovery.
enum MeshAPIClient {
    private static let meshURL = URL(string: "http://localhost:3456/api/mesh/sessions")!
    private static let timeoutSeconds: TimeInterval = 2.0

    struct MeshResponse: Decodable {
        let sessions: [MeshSession]
    }

    struct MeshSession: Decodable {
        let name: String
        let paneId: String?
        let status: String?
        let agent: String?
        let projectPath: String?
        let summary: String?
        let lastActivity: Int?
        let machine: String?
        let machineHost: String?
    }

    /// Fetch sessions from the web server. Returns nil if the server is unreachable or returns invalid data.
    static func fetchMeshSessions() async -> [ClaudeSession]? {
        var request = URLRequest(url: meshURL)
        request.timeoutInterval = timeoutSeconds

        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            data = d
        } catch {
            return nil
        }

        guard let meshResponse = try? JSONDecoder().decode(MeshResponse.self, from: data) else {
            return nil
        }

        return meshResponse.sessions.map { s in
            let status: ClaudeSession.SessionStatus = switch s.status {
            case "working": .working
            case "needsInput": .needsInput
            case "idle": .idle
            default: .unknown
            }

            let activity: Date? = s.lastActivity.flatMap { ts in
                ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil
            }

            return ClaudeSession(
                id: "mesh-\(s.machineHost ?? "local")-\(s.name)",
                pid: 0,
                tty: "",
                sessionUUID: nil,
                tmuxPane: s.paneId,
                tmuxSession: s.name,
                projectPath: s.projectPath,
                summary: s.summary,
                agent: s.agent ?? "shell",
                status: status,
                lastSeen: Date(),
                lastActivity: activity,
                machine: s.machine,
                machineHost: s.machineHost
            )
        }
    }
}
