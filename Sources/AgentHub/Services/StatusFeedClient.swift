import Foundation

/// Subscribes to the web server's `/ws/status` feed.
///
/// The feed pushes a full snapshot of the mesh's sessions whenever anything
/// changes, so the app learns about status changes as they happen instead of
/// polling for them. While the feed is live the app does not need to poll
/// `/api/mesh/sessions` at all.
@MainActor
final class StatusFeedClient {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
    }

    /// The server's address, e.g. "http://localhost:3456".
    private(set) var serverURL: String

    /// Called on the main actor with each snapshot the feed pushes.
    var onSnapshot: (([ClaudeSession]) -> Void)?
    /// Called when the feed connects or drops.
    var onStateChange: ((State) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private(set) var state: State = .idle

    /// How long to wait before trying the feed again after it drops.
    private static let reconnectDelay: Duration = .seconds(2)

    init(serverURL: String) {
        self.serverURL = serverURL
    }

    /// The websocket URL for the status feed.
    nonisolated static func feedURL(serverURL: String) -> URL? {
        var text = serverURL
        if text.hasPrefix("https://") {
            text = "wss://" + text.dropFirst("https://".count)
        } else if text.hasPrefix("http://") {
            text = "ws://" + text.dropFirst("http://".count)
        } else {
            return nil
        }
        return URL(string: text + "/ws/status")
    }

    /// What the feed pushes.
    private struct FeedMessage: Decodable {
        let type: String
        let sessions: [MeshAPIClient.MeshSession]
    }

    /// Decodes a pushed snapshot into the app's sessions.
    ///
    /// Returns nil for anything that is not a session snapshot, so a stray
    /// message never wipes the sidebar.
    nonisolated static func decodeSnapshot(_ data: Data) -> [ClaudeSession]? {
        guard let message = try? JSONDecoder().decode(FeedMessage.self, from: data) else { return nil }
        guard message.type == "sessions" else { return nil }
        return MeshAPIClient.mapSessions(message.sessions)
    }

    // MARK: - Connection

    func connect() {
        guard task == nil else { return }
        guard let url = Self.feedURL(serverURL: serverURL) else {
            setState(.disconnected)
            return
        }

        setState(.connecting)
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, error == nil else { return }
                self.setState(.connected)
            }
        }
        receiveLoop()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        setState(.idle)
    }

    private func receiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.task else { return }
                do {
                    let message = try await task.receive()
                    self.handle(message)
                } catch {
                    self.handleFailure()
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }
        setState(.connected)
        guard let sessions = Self.decodeSnapshot(data) else { return }
        onSnapshot?(sessions)
    }

    private func handleFailure() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        receiveTask?.cancel()
        receiveTask = nil
        setState(.disconnected)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.reconnectDelay)
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }
}
