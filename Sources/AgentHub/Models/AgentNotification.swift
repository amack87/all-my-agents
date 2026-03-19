import Foundation

struct AgentNotification: Identifiable, Sendable {
    enum Status: String, Sendable, Codable {
        case waitingForInput = "waiting_for_input"
        case completed
        case error
    }

    enum StatusSource: Sendable {
        case webhook
        case tmux
    }

    let id: UUID
    let agent: String
    let status: Status
    let appBundleID: String
    let windowTitle: String
    let pid: pid_t
    let sessionName: String
    let message: String
    let timestamp: Date
    let receivedAt: Date
    let sessionID: String?
    let tmuxPane: String?
    let tmuxSession: String?
    let statusSource: StatusSource

    init(from payload: WebhookPayload) {
        self.id = UUID()
        self.agent = payload.agent
        self.status = Status(rawValue: payload.status) ?? .completed
        self.appBundleID = payload.appBundleID
        self.windowTitle = payload.windowTitle
        self.pid = pid_t(payload.pid)
        self.sessionName = payload.sessionName
        self.message = payload.message
        self.receivedAt = Date()
        self.sessionID = payload.sessionID
        self.tmuxPane = payload.tmuxPane
        self.tmuxSession = payload.tmuxSession
        self.statusSource = .webhook

        let formatter = ISO8601DateFormatter()
        self.timestamp = formatter.date(from: payload.timestamp) ?? Date()
    }

    /// Creates a copy with updated fields (immutable pattern)
    func copy(
        status: Status? = nil,
        message: String? = nil,
        sessionID: String?? = nil,
        tmuxPane: String?? = nil,
        tmuxSession: String?? = nil,
        statusSource: StatusSource? = nil
    ) -> AgentNotification {
        AgentNotification(
            id: self.id,
            agent: self.agent,
            status: status ?? self.status,
            appBundleID: self.appBundleID,
            windowTitle: self.windowTitle,
            pid: self.pid,
            sessionName: self.sessionName,
            message: message ?? self.message,
            timestamp: self.timestamp,
            receivedAt: self.receivedAt,
            sessionID: sessionID ?? self.sessionID,
            tmuxPane: tmuxPane ?? self.tmuxPane,
            tmuxSession: tmuxSession ?? self.tmuxSession,
            statusSource: statusSource ?? self.statusSource
        )
    }

    /// Direct memberwise init for copy() and tmux-sourced notifications
    init(
        id: UUID = UUID(),
        agent: String,
        status: Status,
        appBundleID: String = "",
        windowTitle: String = "",
        pid: pid_t = 0,
        sessionName: String,
        message: String,
        timestamp: Date = Date(),
        receivedAt: Date = Date(),
        sessionID: String? = nil,
        tmuxPane: String? = nil,
        tmuxSession: String? = nil,
        statusSource: StatusSource = .tmux
    ) {
        self.id = id
        self.agent = agent
        self.status = status
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.pid = pid
        self.sessionName = sessionName
        self.message = message
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.sessionID = sessionID
        self.tmuxPane = tmuxPane
        self.tmuxSession = tmuxSession
        self.statusSource = statusSource
    }
}

struct WebhookPayload: Decodable, Sendable {
    let agent: String
    let status: String
    let appBundleID: String
    let windowTitle: String
    let pid: Int32
    let sessionName: String
    let message: String
    let timestamp: String
    let tmuxPane: String?
    let tmuxSession: String?
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case agent, status, pid, message, timestamp
        case appBundleID = "app_bundle_id"
        case windowTitle = "window_title"
        case sessionName = "session_name"
        case tmuxPane = "tmux_pane"
        case tmuxSession = "tmux_session"
        case sessionID = "session_id"
    }
}
