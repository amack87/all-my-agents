import Foundation

/// Discovers Claude Code sessions via ps + tmux + enrichment from session files.
/// When the All My Agents web server is running on localhost:3456, uses its
/// mesh API for multi-machine session discovery. Falls back to local-only
/// tmux discovery when the server is unavailable.
@MainActor
final class SessionMonitor {
    private let store: NotificationStore
    private var timer: Timer?

    /// Mesh API backoff: skip mesh attempts for N polls after a failure
    /// to avoid 2-second timeouts on every 1-second poll when the server is down.
    private var meshSkipRemaining: Int = 0
    private static let meshBackoffPolls = 5

    /// Whether we've ever had a successful mesh response. When true and mesh
    /// temporarily fails, we keep the last known sessions instead of falling
    /// back to local-only (which would cause remote sessions to flicker away).
    private var meshEverSucceeded: Bool = false

    init(store: NotificationStore) {
        self.store = store
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        Task.detached(priority: .utility) { [weak self] in
            // Try mesh API first (multi-machine), fall back to local discovery
            let meshSkip = await MainActor.run { self?.meshSkipRemaining ?? 0 }

            if meshSkip <= 0 {
                if let meshSessions = await MeshAPIClient.fetchMeshSessions() {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.meshSkipRemaining = 0
                        self.meshEverSucceeded = true
                        self.store.updateSessions(meshSessions)
                        self.syncNotifications(sessions: meshSessions)
                    }
                    return
                } else {
                    let wasConnected = await MainActor.run { self?.meshEverSucceeded ?? false }
                    await MainActor.run { [weak self] in
                        self?.meshSkipRemaining = Self.meshBackoffPolls
                    }
                    // If mesh was previously working, keep the last known sessions
                    // rather than falling back to local-only (which drops remote sessions).
                    if wasConnected { return }
                }
            } else {
                let wasConnected = await MainActor.run { self?.meshEverSucceeded ?? false }
                await MainActor.run { [weak self] in
                    self?.meshSkipRemaining -= 1
                }
                // During backoff, keep last known sessions if mesh was previously working
                if wasConnected { return }
            }

            // Fallback: local-only tmux discovery (only reached if mesh never succeeded)
            // 1. Discover Claude processes via ps
            let psOutput = await Self.runProcess("/bin/ps", arguments: ["-eo", "pid,tty,args"])
            let processes = Self.parseProcesses(from: psOutput)

            // 2. Map TTYs to tmux panes
            let ttyMap = await Self.mapTTYToPanes()

            // 3. Get all tmux sessions (so we keep sessions even when Claude exits)
            let allTmuxPanes = await Self.listAllTmuxPanes()

            // 4. Build enrichment from sessions-index.json
            let enrichment = Self.buildEnrichmentMap()

            // 5. Build sessions from Claude processes (these have full info)
            var seenPanes = Set<String>()
            var paneStatuses: [String: ClaudeSession.SessionStatus] = [:]

            for proc in processes {
                if let paneID = ttyMap[proc.tty]?.pane {
                    paneStatuses[paneID] = await Self.checkPaneState(paneID: paneID)
                    seenPanes.insert(paneID)
                }
            }

            // 5b. Detect agents for all tmux panes (by pane PID)
            let paneAgents = await Self.detectAgentsForPanes(allTmuxPanes)

            var sessions = processes.map { proc -> ClaudeSession in
                let indexed = proc.sessionUUID.flatMap { enrichment[$0] }
                let tmuxInfo = ttyMap[proc.tty]
                let paneID = tmuxInfo?.pane
                let status = paneID.flatMap { paneStatuses[$0] } ?? .unknown
                let agent = paneID.flatMap { paneAgents[$0] } ?? "Claude Code"

                return ClaudeSession(
                    id: proc.sessionUUID ?? "pid-\(proc.pid)",
                    pid: proc.pid,
                    tty: proc.tty,
                    sessionUUID: proc.sessionUUID,
                    tmuxPane: tmuxInfo?.pane,
                    tmuxSession: tmuxInfo?.session,
                    projectPath: indexed?.projectPath,
                    summary: indexed?.summary,
                    agent: agent,
                    status: status,
                    lastSeen: Date(),
                    lastActivity: tmuxInfo?.activity,
                    machine: nil,
                    machineHost: nil
                )
            }

            // 6. Add tmux sessions that don't have a Claude process running.
            //    These are sessions where Claude exited but the tmux session persists.
            //    Also skip sessions whose name already appeared from a Claude process
            //    to avoid duplicates (e.g. when the pane IDs differ between steps).
            let seenSessionNames = Set(sessions.compactMap(\.tmuxSession))
            for paneInfo in allTmuxPanes where !seenPanes.contains(paneInfo.pane) {
                guard !seenSessionNames.contains(paneInfo.session) else { continue }
                let status = await Self.checkPaneState(paneID: paneInfo.pane)
                let agent = paneAgents[paneInfo.pane] ?? "shell"
                sessions.append(ClaudeSession(
                    id: "tmux-\(paneInfo.pane)",
                    pid: 0,
                    tty: "",
                    sessionUUID: nil,
                    tmuxPane: paneInfo.pane,
                    tmuxSession: paneInfo.session,
                    projectPath: nil,
                    summary: nil,
                    agent: agent,
                    status: status,
                    lastSeen: Date(),
                    lastActivity: paneInfo.activity,
                    machine: nil,
                    machineHost: nil
                ))
            }

            // 7. Update store on main actor
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.store.updateSessions(sessions)
                self.syncNotifications(sessions: sessions)
            }
        }
    }

    // MARK: - Notification Sync

    /// Bridge discovered sessions into the notification store for speedrun support.
    private func syncNotifications(sessions: [ClaudeSession]) {
        let activePanes = Set(sessions.compactMap(\.tmuxPane))

        // Remove notifications for panes that no longer exist
        for notification in store.notifications where notification.statusSource == .tmux {
            if let pane = notification.tmuxPane, !activePanes.contains(pane) {
                store.removeTmuxPane(pane)
            }
        }

        // Upsert from discovered sessions
        for session in sessions {
            guard let pane = session.tmuxPane else { continue }
            let status: AgentNotification.Status = session.status == .needsInput ? .waitingForInput : .completed
            store.upsertFromTmux(
                tmuxPane: pane,
                tmuxSession: session.tmuxSession,
                status: status,
                sessionName: session.displayName,
                sessionID: session.sessionUUID
            )
        }
    }

    // MARK: - Shell Execution

    /// Run a process and return stdout. Uses DispatchQueue to avoid blocking Swift concurrency threads.
    nonisolated private static func runProcess(_ executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output)
            }
        }
    }

    // MARK: - Process Discovery

    private struct RawProcess: Sendable {
        let pid: pid_t
        let tty: String
        let sessionUUID: String?
    }

    nonisolated private static func parseProcesses(from output: String?) -> [RawProcess] {
        guard let output else { return [] }

        return output
            .components(separatedBy: "\n")
            .compactMap { line -> RawProcess? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Match any claude process on a real TTY (not "??")
                guard trimmed.contains("/claude") || trimmed.contains(" claude ") else { return nil }
                guard !trimmed.contains("grep") else { return nil }
                guard !trimmed.contains("--print") else { return nil }

                let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 3 else { return nil }

                guard let pid = pid_t(parts[0]) else { return nil }
                let tty = String(parts[1])
                // Skip processes not on a real TTY
                guard tty != "??" else { return nil }
                let command = String(parts[2])
                let uuid = extractSessionUUID(from: command)

                return RawProcess(pid: pid, tty: tty, sessionUUID: uuid)
            }
    }

    /// Extract session UUID from --session-id or --resume flags.
    nonisolated private static func extractSessionUUID(from command: String) -> String? {
        for flag in ["--session-id ", "--resume "] {
            if let range = command.range(of: flag) {
                let after = command[range.upperBound...]
                let uuid = after.prefix(while: { !$0.isWhitespace })
                if uuid.count == 36, uuid.contains("-") {
                    return String(uuid)
                }
            }
        }
        return nil
    }

    // MARK: - TTY-to-Tmux Mapping

    private static let tmuxSep = "|||"

    private struct TmuxPaneInfo: Sendable {
        let pane: String    // e.g. "%3"
        let session: String // e.g. "agent-1"
        let activity: Date? // tmux session_activity (unix epoch)
    }

    /// Map TTY device names to tmux pane IDs and session names.
    nonisolated private static func mapTTYToPanes() async -> [String: TmuxPaneInfo] {
        guard let output = await TmuxHelpers.run(arguments: [
            "list-panes", "-a", "-F",
            "#{pane_tty}\(tmuxSep)#{pane_id}\(tmuxSep)#{session_name}\(tmuxSep)#{session_activity}"
        ]) else { return [:] }

        var result: [String: TmuxPaneInfo] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: tmuxSep)
            guard parts.count >= 4 else { continue }

            let fullTTY = parts[0]
            let paneID = parts[1]
            let sessionName = parts[2]
            let activity = TimeInterval(parts[3]).map { Date(timeIntervalSince1970: $0) }

            // Extract short TTY name for matching with ps output.
            // tmux gives "/dev/ttys090", ps gives "ttys090" — strip "/dev/" prefix.
            let shortTTY = fullTTY.hasPrefix("/dev/") ? String(fullTTY.dropFirst(5)) : fullTTY

            result[shortTTY] = TmuxPaneInfo(pane: paneID, session: sessionName, activity: activity)
        }

        return result
    }

    /// List all tmux panes across all sessions. Used to keep sessions visible
    /// even when no Claude process is running (e.g. after /exit).
    /// Deduplicates by session group — only returns one pane per base session
    /// to avoid showing hundreds of grouped sessions created by All My Agents.
    nonisolated private static func listAllTmuxPanes() async -> [TmuxPaneInfo] {
        guard let output = await TmuxHelpers.run(arguments: [
            "list-panes", "-a", "-F",
            "#{pane_id}\(tmuxSep)#{session_name}\(tmuxSep)#{session_group}\(tmuxSep)#{session_activity}"
        ]) else { return [] }

        var seenGroups = Set<String>()
        var result: [TmuxPaneInfo] = []

        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: tmuxSep)
            guard parts.count >= 4 else { continue }
            let paneID = parts[0]
            let sessionName = parts[1]
            let group = parts[2]
            let activity = TimeInterval(parts[3]).map { Date(timeIntervalSince1970: $0) }

            // Skip our own grouped sessions (created by TerminalSession)
            if sessionName.hasPrefix("_ah_") { continue }

            // For grouped sessions, only include the base session (name == group)
            // or the first one we encounter in that group.
            if !group.isEmpty {
                if seenGroups.contains(group) { continue }
                seenGroups.insert(group)
                result.append(TmuxPaneInfo(pane: paneID, session: group, activity: activity))
            } else {
                result.append(TmuxPaneInfo(pane: paneID, session: sessionName, activity: activity))
            }
        }

        return result
    }

    // MARK: - Agent Detection

    /// Detect what agent/tool is running in each tmux pane by inspecting the pane's process tree.
    nonisolated private static func detectAgentsForPanes(_ panes: [TmuxPaneInfo]) async -> [String: String] {
        // Get pane PIDs via tmux
        guard let output = await TmuxHelpers.run(arguments: [
            "list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"
        ]) else { return [:] }

        var panePids: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            panePids[String(parts[0])] = String(parts[1])
        }

        var result: [String: String] = [:]
        for pane in panes {
            guard let pid = panePids[pane.pane] else { continue }
            result[pane.pane] = await detectAgent(panePid: pid)
        }
        return result
    }

    /// Identify what agent is running as a child of the given shell PID.
    nonisolated private static func detectAgent(panePid: String) async -> String {
        guard let output = await runProcess("/usr/bin/pgrep", arguments: ["-lP", panePid]) else {
            return "shell"
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let childPid = String(parts[0])
            let childName = String(parts[1])

            if childName == "claude" { return "Claude Code" }
            if childName == "cursor" { return "Cursor" }
            if childName == "aider" { return "Aider" }
            if childName == "copilot" { return "Copilot" }
            if childName == "codex" { return "Codex" }

            // Node-based agents: check full args
            if childName == "node" {
                if let args = await runProcess("/bin/ps", arguments: ["-o", "args=", "-p", childPid]) {
                    let lower = args.lowercased()
                    if lower.contains("codex") { return "Codex" }
                    if lower.contains("claude") { return "Claude Code" }
                    if lower.contains("cursor") { return "Cursor" }
                    if lower.contains("aider") { return "Aider" }
                }
            }

            // Claude Code version-string process name (e.g. "2.1.77")
            if childName.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                if let comm = await runProcess("/bin/ps", arguments: ["-o", "comm=", "-p", childPid]) {
                    if comm.trimmingCharacters(in: .whitespacesAndNewlines) == "claude" {
                        return "Claude Code"
                    }
                }
            }
        }

        return "shell"
    }

    // MARK: - Pane State Detection

    /// Analyze a tmux pane to determine session status by scanning capture-pane output.
    ///
    /// Detection strategy (checked in priority order):
    ///
    /// **Working indicators** (agent actively processing):
    /// - "esc to interrupt" in status bar — agent is mid-tool-call
    /// - "Computing..." / "Reading..." / etc. with elapsed time pattern
    /// - No command prompt (`❯` alone on a line) visible at all
    ///
    /// **Needs-input indicators** (awaiting user response):
    /// - "Esc to cancel" in status bar — tool approval dialog
    /// - Selection UI: `❯` prefixing a numbered option (e.g. `❯ 1. Yes`)
    /// - Numbered options (1. / 2. / 1) / 2)) in recent content
    /// - Permission prompts: "Allow", "(Y/n)", "(y/N)"
    /// - Question ending with "?" in recent output
    ///
    /// **Idle** (at command prompt, finished work):
    /// - `❯` prompt visible with none of the above signals
    nonisolated private static func checkPaneState(paneID: String) async -> ClaudeSession.SessionStatus {
        guard let output = await TmuxHelpers.run(arguments: [
            "capture-pane", "-t", paneID, "-p", "-J"
        ]) else { return .unknown }

        let lines = output.components(separatedBy: "\n")
        let tail = lines.suffix(20)

        // --- Pass 1: Check status bar / hint lines for strong signals ---
        for line in tail {
            let lower = line.lowercased()

            // "esc to interrupt" = agent is actively working on a tool call
            if lower.contains("esc to interrupt") { return .working }

            // Progress indicator: "Computing...", "Reading...", etc. with elapsed time
            if lower.contains("...") && lower.contains("token") { return .working }

            // "Generating.." / "Generating..." = agent is streaming a response
            if lower.contains("generating") { return .working }

            // Status bar progress: "Auto · 55.5% · 2 files edited" (middle-dot + percentage)
            if lower.contains("·") && lower.contains("%") { return .working }
        }

        for line in tail {
            let lower = line.lowercased()

            // "Esc to cancel" = tool approval dialog awaiting input
            if lower.contains("esc to cancel") { return .needsInput }

            // Permission prompts
            if lower.contains("(y/n)") || lower.contains("(y/n)") { return .needsInput }
            if lower.contains("allow") && lower.contains("?") { return .needsInput }
        }

        // --- Pass 2: Check for command prompt and selection UI ---
        // The Claude Code command prompt is `❯` alone (or `❯ ` followed by typed text).
        // The selection UI cursor is `❯ 1.` or `❯ 2.` (numbered option with dot).
        var hasCommandPrompt = false
        var hasSelectionCursor = false

        for line in tail {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("❯") else { continue }

            let afterCursor = String(trimmed.dropFirst("❯".count))
                .trimmingCharacters(in: .whitespaces)

            // Selection cursor: ❯ followed by digit + "." (e.g. "❯ 1. Yes")
            if afterCursor.count >= 2,
               afterCursor.first?.isNumber == true,
               afterCursor[afterCursor.index(after: afterCursor.startIndex)] == "." {
                hasSelectionCursor = true
            } else {
                hasCommandPrompt = true
            }
        }

        if hasSelectionCursor { return .needsInput }

        // No prompt at all = still working
        guard hasCommandPrompt else { return .working }

        // --- Pass 3: Prompt visible — scan the LAST agent output block above prompt ---
        // Only scan between the prompt and the nearest boundary (tool marker, divider,
        // or previous prompt) to avoid false positives from old conversation history.
        var contentAbovePrompt: [String] = []
        var foundPrompt = false
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !foundPrompt {
                if trimmed == "❯" || trimmed.hasPrefix("❯") {
                    foundPrompt = true
                }
                continue
            }
            // Stop at boundaries: previous prompt, tool output markers, dividers
            if trimmed == "❯" || trimmed.hasPrefix("❯") { break }
            if trimmed.hasPrefix("✻") || trimmed.hasPrefix("⎿") { break }
            if trimmed.contains("─────") { break }
            contentAbovePrompt.append(trimmed)
            if contentAbovePrompt.count >= 15 { break }
        }

        // Known Claude Code UI lines that should NOT be treated as questions
        let uiPatterns = [
            "? for shortcuts",
            "for shortcuts",
            "esc to cancel",
            "esc to interrupt",
            "tab to amend",
            "ctrl+e to explain",
            "shift+tab to cycle",
            "accept edits on",
        ]

        for line in contentAbovePrompt {
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            // Skip Claude Code UI/status bar lines
            if uiPatterns.contains(where: { lower.contains($0) }) { continue }
            // Skip separator lines (──────)
            if line.allSatisfy({ $0 == "─" || $0 == "─" || $0 == "▪" || $0 == " " || $0 == "─" }) { continue }
            if line.contains("─────") { continue }

            // Question ending with "?" (but not lines that ARE just "?")
            if line.hasSuffix("?") && line.count > 1 { return .needsInput }

            // Numbered options: "1.", "2.", "1)", "2)" at start
            if line.count >= 2 {
                let first = line.first!
                let second = line[line.index(after: line.startIndex)]
                if first.isNumber && (second == "." || second == ")") {
                    return .needsInput
                }
            }
        }

        return .idle
    }

    // MARK: - Session Enrichment

    private struct SessionInfo {
        let projectPath: String?
        let summary: String?
    }

    /// Build a map of sessionUUID -> project info by scanning:
    /// 1. JSONL files in ~/.claude/projects/*/<uuid>.jsonl (directory name -> project path)
    /// 2. sessions-index.json for summary and explicit projectPath
    nonisolated private static func buildEnrichmentMap() -> [String: SessionInfo] {
        let claudeDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir) else { return [:] }

        // First pass: sessions-index.json for summaries and explicit project paths
        var summaries: [String: String] = [:]
        var indexProjectPaths: [String: String] = [:]

        for dir in projectDirs {
            let indexPath = claudeDir + "/" + dir + "/sessions-index.json"
            guard fm.fileExists(atPath: indexPath),
                  let data = fm.contents(atPath: indexPath),
                  let index = try? JSONDecoder().decode(SessionsIndexFile.self, from: data) else { continue }

            for entry in index.entries {
                if let summary = entry.summary {
                    summaries[entry.sessionId] = summary
                }
                if let path = entry.projectPath {
                    indexProjectPaths[entry.sessionId] = path
                } else if let path = index.originalPath {
                    indexProjectPaths[entry.sessionId] = path
                }
            }
        }

        // Second pass: scan for <uuid>.jsonl files to discover all sessions
        var dirOriginalPaths: [String: String] = [:]
        for dir in projectDirs {
            let indexPath = claudeDir + "/" + dir + "/sessions-index.json"
            if fm.fileExists(atPath: indexPath),
               let data = fm.contents(atPath: indexPath),
               let index = try? JSONDecoder().decode(SessionsIndexFile.self, from: data),
               let origPath = index.originalPath {
                dirOriginalPaths[dir] = origPath
            }
        }

        var result: [String: SessionInfo] = [:]

        for dir in projectDirs {
            let dirPath = claudeDir + "/" + dir
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            let projectPath = dirOriginalPaths[dir]

            for file in files where file.hasSuffix(".jsonl") {
                let uuid = String(file.dropLast(6)) // remove ".jsonl"
                guard uuid.count == 36, uuid.contains("-") else { continue }

                result[uuid] = SessionInfo(
                    projectPath: indexProjectPaths[uuid] ?? projectPath,
                    summary: summaries[uuid]
                )
            }
        }

        return result
    }
}

// MARK: - Sessions Index JSON Schema

private struct SessionsIndexFile: Decodable {
    let version: Int
    let entries: [SessionIndexEntry]
    let originalPath: String?
}

private struct SessionIndexEntry: Decodable {
    let sessionId: String
    let summary: String?
    let firstPrompt: String?
    let projectPath: String?
}
