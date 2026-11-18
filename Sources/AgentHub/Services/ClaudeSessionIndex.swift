import Foundation

/// Discovers Claude session IDs from ~/.claude/sessions/<pid>.json files.
/// These files are written by Claude Code for each running process and contain
/// the session UUID needed to resume a conversation faithfully.
enum ClaudeSessionIndex {
    /// A parsed session file from ~/.claude/sessions/<pid>.json
    struct SessionRecord: Sendable {
        let pid: pid_t
        let sessionId: String
        let tmux: String?  // e.g. "session-name:@6.%6"
        let cwd: String?
    }

    /// Read all session records from ~/.claude/sessions/
    /// Returns a map of pane ID -> session record
    static func readAllRecords() -> [String: SessionRecord] {
        let sessionsDir = NSHomeDirectory() + "/.claude/sessions"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            return [:]
        }

        var result: [String: SessionRecord] = [:]

        for file in files where file.hasSuffix(".json") {
            let path = sessionsDir + "/" + file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String else {
                continue
            }

            // Validate the sessionId format (UUID)
            guard sessionId.count == 36, sessionId.contains("-") else { continue }

            let tmux = json["tmux"] as? String
            let cwd = json["cwd"] as? String

            let record = SessionRecord(
                pid: pid_t(pid),
                sessionId: sessionId,
                tmux: tmux,
                cwd: cwd
            )

            // Index by pane ID if we have a tmux reference
            if let tmux = tmux, let paneId = paneIdFromTmuxTarget(tmux) {
                result[paneId] = record
            }

            // Also index by PID for direct lookup
            result["pid:\(pid)"] = record
        }

        return result
    }

    /// Extract pane ID from a tmux target like "session:@6.%6" -> "%6"
    private static func paneIdFromTmuxTarget(_ target: String) -> String? {
        // Match the trailing pane id: "session:@6.%6" -> "%6"
        // The pattern is "session_name:@window.pane" where pane starts with %
        let components = target.components(separatedBy: ".")
        guard let last = components.last, last.hasPrefix("%") else {
            return nil
        }
        return last
    }

    /// Get the session ID for a given tmux session name by:
    /// 1. Finding the pane ID for the session
    /// 2. Looking up the session record by pane ID
    static func sessionId(forTmuxSession sessionName: String) -> String? {
        let records = readAllRecords()

        // Find the pane for this tmux session (synchronous, uses blocking I/O)
        guard let paneId = findPaneIdSync(forSession: sessionName) else {
            return nil
        }

        return records[paneId]?.sessionId
    }

    /// Find a pane ID for a given tmux session name (synchronous, blocking)
    private static func findPaneIdSync(forSession sessionName: String) -> String? {
        // Use Process directly to avoid async/await issues
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/tmux")
        process.arguments = ["list-panes", "-t", sessionName, "-F", "#{pane_id}"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let output, !output.isEmpty else { return nil }

            // Return the first pane (assuming single-pane sessions)
            let panes = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            return panes.first
        } catch {
            return nil
        }
    }

    /// Get session record by PID (direct lookup)
    static func record(forPid pid: pid_t) -> SessionRecord? {
        let records = readAllRecords()
        return records["pid:\(pid)"]
    }
}