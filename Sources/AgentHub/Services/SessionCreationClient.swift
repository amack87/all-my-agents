import Foundation

/// Creates sessions through the All My Agents web server, exactly like the
/// web client does.
///
/// Going through the server is what makes a session restorable: the server
/// records the launch spec, the registry keeps it, and a reboot replays it
/// instead of recreating a bare shell. It also mints the surface token the
/// agent-status adapters need, so status becomes event-sourced rather than
/// screen-scraped.
enum SessionCreationClient {
    enum Result {
        case success
        case failure(String)
    }

    private static let timeoutSeconds: TimeInterval = 5.0

    private struct ErrorBody: Decodable {
        let error: String?
    }

    /// The server's identity — this machine's name and its mesh peers.
    static func fetchIdentity(serverURL: String) async -> ServerIdentity? {
        guard let url = URL(string: serverURL + "/api/identity") else { return nil }
        guard let data = await get(url) else { return nil }
        return try? JSONDecoder().decode(ServerIdentity.self, from: data)
    }

    /// The machines a session can reach through a launch command (e.g. SSH).
    static func fetchTargets(serverURL: String) async -> [ServerTarget] {
        guard let url = URL(string: serverURL + "/api/targets") else { return [] }
        guard let data = await get(url) else { return [] }
        return (try? JSONDecoder().decode([ServerTarget].self, from: data)) ?? []
    }

    /// Create a session on the machine the request names.
    static func create(
        name: String,
        request: SessionRequest,
        serverURL: String
    ) async -> Result {
        let path: String
        let body: [String: String]

        switch request {
        case .local(let name):
            path = "/api/sessions"
            body = ["name": name]
        case .target(let name, let target):
            path = "/api/sessions"
            body = ["name": name, "target": target]
        case .peer(let name, let host):
            path = "/api/proxy/\(host)/sessions"
            body = ["name": name]
        }

        guard let url = URL(string: serverURL + path) else {
            return .failure("Invalid server address: \(serverURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Unexpected response from the server")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                return .failure(message ?? "The server returned status \(http.statusCode)")
            }
            return .success
        } catch {
            return .failure("Could not reach the server at \(serverURL)")
        }
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
