import Foundation

/// Fetches aggregated sessions from the All My Agents web server's mesh API.
/// Returns nil on any failure (server not running, timeout, decode error),
/// signaling the caller to fall back to local-only discovery.
enum MeshAPIClient {
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
    static func fetchMeshSessions(serverURL: String = "http://localhost:3456") async -> [ClaudeSession]? {
        guard let url = URL(string: serverURL + "/api/mesh/sessions") else { return nil }
        var request = URLRequest(url: url)
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

        return mapSessions(meshResponse.sessions)
    }

    /// Maps the server's session payloads onto the app's model.
    ///
    /// Both transports use this: the HTTP poll of `/api/mesh/sessions` and the
    /// `/ws/status` feed. They must agree, or the app shows different sessions
    /// depending on which transport happened to be live.
    static func mapSessions(_ meshSessions: [MeshSession]) -> [ClaudeSession] {
        meshSessions.map { s in
            let status = ClaudeSession.SessionStatus(wire: s.status)

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

    // MARK: - Sidebar groups (local-first sync)

    /// Mirrors the web server's `/api/sidebar-groups` envelope. `data` is nil
    /// when the server has no stored copy yet.
    struct SidebarGroupsResponse: Decodable {
        let data: SidebarOrderData?
        let updatedAt: Int64?
    }

    /// Fetch the server's sidebar order copy. Nil if unreachable. When the
    /// server has no stored copy yet, returns an empty entry (timestamp 0) so
    /// callers can still decide to push their local copy.
    static func fetchSidebarGroups(
        serverURL: String = "http://localhost:3456"
    ) async -> SidebarOrderEntry? {
        guard let url = URL(string: serverURL + "/api/sidebar-groups") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(SidebarGroupsResponse.self, from: data)
            return SidebarOrderEntry(data: decoded.data ?? .empty(), updatedAt: decoded.updatedAt ?? 0)
        } catch {
            return nil
        }
    }

    /// Push the local copy (POST /api/sidebar-groups). Returns the server's
    /// stored winner — it may be a newer copy the server already had.
    static func pushSidebarGroups(
        _ entry: SidebarOrderEntry,
        serverURL: String = "http://localhost:3456"
    ) async -> SidebarOrderEntry? {
        guard let url = URL(string: serverURL + "/api/sidebar-groups") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        request.httpBody = try? JSONEncoder().encode(entry)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(SidebarGroupsResponse.self, from: data)
            guard let orderData = decoded.data else { return nil }
            return SidebarOrderEntry(data: orderData, updatedAt: decoded.updatedAt ?? 0)
        } catch {
            return nil
        }
    }
}
