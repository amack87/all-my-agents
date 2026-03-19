import Foundation

struct ClaudeSession: Identifiable, Sendable, Equatable {
    enum SessionStatus: Sendable, Equatable {
        case working      // actively processing (no prompt visible)
        case needsInput   // waiting for user — asked a question or has pending edits
        case idle         // finished work, sitting at prompt
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
