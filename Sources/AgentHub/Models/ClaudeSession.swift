import Foundation

struct ClaudeSession: Identifiable, Sendable, Equatable {
    enum SessionStatus: Sendable, Equatable, CaseIterable {
        case working      // actively processing (no prompt visible)
        case needsInput   // waiting for user — asked a question or has pending edits
        case idle         // finished work, sitting at prompt
        case ended        // the agent's session is over — it exited or was shut down
        case unknown
    }

    let id: String             // sessionUUID or "pid-\(pid)" fallback
    let pid: pid_t
    let tty: String            // e.g. "s011"
    let sessionUUID: String?
    let tmuxPane: String?      // e.g. "%3"
    let tmuxSession: String?   // e.g. "agent-1"
    let projectPath: String?   // from sessions-index.json
    let summary: String?       // from sessions-index.json
    let agent: String          // e.g. "Claude Code", "Cursor", "shell"
    let status: SessionStatus
    let lastSeen: Date
    let lastActivity: Date?    // tmux session_activity — last input/output timestamp
    let machine: String?       // nil = local-only discovery, "MBP M4" etc. from mesh
    let machineHost: String?   // nil or "local" = this machine, "100.x.x.x:3456" = remote peer
    let task: String?          // what the agent says it is doing right now
    let group: String?         // which group the server says the session belongs to (ADR 0017)
    let dir: String?           // the directory the session's pane runs in
    let state: String?         // the task's state, where its workflow stands (ADR 0017/0018); server-owned, opaque here

    /// Whether this session lives on a remote machine (needs WebSocket proxy).
    var isRemote: Bool {
        guard let host = machineHost else { return false }
        return host != "local"
    }

    var displayName: String {
        if let name = tmuxSession, !name.isEmpty {
            return name
        }
        if let path = projectPath {
            return (path as NSString).lastPathComponent
        }
        if let uuid = sessionUUID { return String(uuid.prefix(8)) }
        return "PID \(pid)"
    }

    /// The tmux target for attaching — prefer pane ID, fall back to session name
    var terminalTarget: String? {
        tmuxPane ?? tmuxSession
    }
}
