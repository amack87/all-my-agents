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

    // MARK: - Server Settings (backup + shutdown-hibernate)

    /// Mirrors the web server's `/api/settings` payload.
    struct ServerSettings: Codable, Equatable {
        struct Backup: Codable, Equatable {
            var enabled: Bool
            var intervalMinutes: Int
        }
        struct ShutdownHibernate: Codable, Equatable {
            var enabled: Bool
        }
        var backup: Backup
        var shutdownHibernate: ShutdownHibernate

        static let defaults = ServerSettings(
            backup: Backup(enabled: true, intervalMinutes: 60),
            shutdownHibernate: ShutdownHibernate(enabled: true)
        )
    }

    /// Fetch the web server's backup/shutdown settings. Nil if unreachable.
    static func fetchSettings(serverURL: String = "http://localhost:3456") async -> ServerSettings? {
        guard let url = URL(string: serverURL + "/api/settings") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(ServerSettings.self, from: data)
        } catch {
            return nil
        }
    }

    /// Push settings to the web server (PUT /api/settings). Returns true on success.
    static func saveSettings(
        _ settings: ServerSettings,
        serverURL: String = "http://localhost:3456"
    ) async -> Bool {
        guard let url = URL(string: serverURL + "/api/settings") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        request.httpBody = try? JSONEncoder().encode(settings)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
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

    /// Trigger a one-off backup of all active sessions on the server (POST /api/backup/run).
    /// Returns a human-readable status message.
    static func runBackupNow(serverURL: String = "http://localhost:3456") async -> String {
        guard let url = URL(string: serverURL + "/api/backup/run") else { return "Invalid server URL" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "No response" }
            if http.statusCode != 200 {
                return "Server error (\(http.statusCode))"
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = obj["error"] as? String { return error }
                if let skipped = obj["skipped"] as? String { return skipped }
                if obj["ok"] as? Bool == true { return "Backup complete" }
            }
            return "Backup complete"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}
