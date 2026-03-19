import SwiftUI

/// Sheet presented when the user taps "+" to add a session to the sidebar.
/// Offers three paths: create a new tmux session, pick an existing one,
/// or restore a hibernated session.
struct AddSessionSheet: View {
    var store: NotificationStore
    var onSelectSession: (ClaudeSession) -> Void

    enum Mode {
        case pick        // choosing new vs existing vs hibernated
        case newSession  // entering a name for a new session
        case existing    // listing tmux sessions to re-add
        case hibernated  // listing hibernated sessions to restore
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .pick
    @State private var newSessionName: String = ""
    @State private var existingSessions: [String] = []
    @State private var hibernatedSessions: [HibernatedSession] = []
    @State private var isCreating: Bool = false
    @State private var isRestoring: String? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            sheetContent
        }
        .frame(width: 280, height: 300)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            if mode != .pick {
                Button(action: { mode = .pick }) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            Text(headerTitle)
                .font(.callout.bold())
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        switch mode {
        case .pick: return "Add Session"
        case .newSession: return "New Session"
        case .existing: return "Existing Sessions"
        case .hibernated: return "Hibernated Sessions"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var sheetContent: some View {
        switch mode {
        case .pick:
            pickModeContent
        case .newSession:
            newSessionContent
        case .existing:
            existingSessionContent
        case .hibernated:
            hibernatedSessionContent
        }
    }

    // MARK: - Pick Mode

    private var pickModeContent: some View {
        VStack(spacing: 12) {
            Spacer()
            Button(action: { mode = .newSession }) {
                Label("New Session", systemImage: "plus.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: {
                loadExistingSessions()
                mode = .existing
            }) {
                Label("Existing Session", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: {
                loadHibernatedSessions()
                mode = .hibernated
            }) {
                Label("Restore Hibernated", systemImage: "moon.zzz")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - New Session

    private var newSessionContent: some View {
        VStack(spacing: 12) {
            Spacer()
            TextField("Session name", text: $newSessionName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createNewSession() }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(action: createNewSession) {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Create")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(newSessionName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func createNewSession() {
        let name = newSessionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // Validate: no spaces or special chars that tmux dislikes
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            errorMessage = "Use only letters, numbers, hyphens, underscores"
            return
        }

        isCreating = true
        errorMessage = nil

        Task {
            // tmux new-session -d creates detached session; stdout is empty on success
            let _ = await TmuxHelpers.run(arguments: [
                "new-session", "-d", "-s", name
            ])

            // Verify the session was actually created
            let verifyOutput = await TmuxHelpers.run(arguments: [
                "has-session", "-t", name
            ])

            await MainActor.run {
                isCreating = false

                // has-session returns empty string on success, nil on failure
                guard verifyOutput != nil else {
                    errorMessage = "Failed to create tmux session"
                    return
                }

                // Unhide if it was previously hidden
                store.unhideSession(named: name)

                // Tell the store to select this session once the monitor discovers it
                store.setPendingSession(named: name)

                // Navigate immediately using the session name as tmux target
                let session = store.sessions.first(where: { $0.tmuxSession == name })
                    ?? ClaudeSession(
                        id: "tmux-pending-\(name)",
                        pid: 0,
                        tty: "",
                        sessionUUID: nil,
                        tmuxPane: nil,
                        tmuxSession: name,
                        projectPath: nil,
                        summary: nil,
                        agent: "shell",
                        status: .idle,
                        lastSeen: Date(),
                        lastActivity: nil
                    )
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onSelectSession(session)
                }
            }
        }
    }

    // MARK: - Existing Sessions

    private var existingSessionContent: some View {
        VStack(spacing: 0) {
            if existingSessions.isEmpty {
                Spacer()
                Text("No tmux sessions found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(existingSessions, id: \.self) { name in
                            existingSessionRow(name: name)
                        }
                    }
                }
            }
        }
    }

    private func existingSessionRow(name: String) -> some View {
        let isHidden = store.hiddenSessionNames.contains(name)
        let alreadyVisible = !isHidden && store.sessions.contains(where: { $0.tmuxSession == name })

        return Button(action: {
            if isHidden {
                store.unhideSession(named: name)
            }
            // Tell the store to select this session once the monitor discovers it
            store.setPendingSession(named: name)

            // Find the session in the store's full list, or use name as tmux target
            let session = store.sessions.first(where: { $0.tmuxSession == name })
                ?? ClaudeSession(
                    id: "tmux-pending-\(name)",
                    pid: 0,
                    tty: "",
                    sessionUUID: nil,
                    tmuxPane: nil,
                    tmuxSession: name,
                    projectPath: nil,
                    summary: nil,
                    agent: "shell",
                    status: .unknown,
                    lastSeen: Date(),
                    lastActivity: nil
                )
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                onSelectSession(session)
            }
        }) {
            HStack {
                Circle()
                    .fill(isHidden ? Color.gray.opacity(0.3) : Color.green.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isHidden {
                    Text("hidden")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if alreadyVisible {
                    Text("visible")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hibernated Sessions

    private var hibernatedSessionContent: some View {
        VStack(spacing: 0) {
            if hibernatedSessions.isEmpty {
                Spacer()
                Text("No hibernated sessions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(hibernatedSessions) { session in
                            hibernatedSessionRow(session: session)
                        }
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func hibernatedSessionRow(session: HibernatedSession) -> some View {
        let isCurrentlyRestoring = isRestoring == session.sessionName

        return Button(action: {
            restoreHibernatedSession(session)
        }) {
            HStack {
                Image(systemName: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.displayDate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isCurrentlyRestoring {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(session.shortDir)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRestoring != nil)
    }

    // MARK: - Hibernation Helpers

    private func restoreHibernatedSession(_ session: HibernatedSession) {
        isRestoring = session.sessionName
        errorMessage = nil

        Task {
            let output = await runHibernatorCommand([
                "restore", "--json", session.sessionName
            ])

            await MainActor.run {
                isRestoring = nil

                guard let output else {
                    errorMessage = "Failed to run hibernator"
                    return
                }

                // Parse JSON response
                guard let data = output.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool,
                      success else {
                    let errMsg = parseRestoreError(output)
                    errorMessage = errMsg ?? "Restore failed"
                    return
                }

                let name = session.sessionName
                store.unhideSession(named: name)
                store.setPendingSession(named: name)

                let restoredSession = ClaudeSession(
                    id: "tmux-pending-\(name)",
                    pid: 0,
                    tty: "",
                    sessionUUID: nil,
                    tmuxPane: nil,
                    tmuxSession: name,
                    projectPath: nil,
                    summary: nil,
                    agent: "shell",
                    status: .idle,
                    lastSeen: Date(),
                    lastActivity: nil
                )
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onSelectSession(restoredSession)
                }
            }
        }
    }

    private func parseRestoreError(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else {
            return nil
        }
        return error
    }

    private func loadHibernatedSessions() {
        Task {
            let output = await runHibernatorCommand(["list", "--json"])
            await MainActor.run {
                guard let output, !output.isEmpty else {
                    hibernatedSessions = []
                    return
                }
                hibernatedSessions = HibernatedSession.parse(json: output)
            }
        }
    }

    /// Path to claude-hibernator CLI. Set HIBERNATOR_CLI env var or defaults to
    /// ~/Repos/claude-hibernator/cli.py. Returns nil if not found.
    private static var hibernatorCLI: String? = {
        if let envPath = ProcessInfo.processInfo.environment["HIBERNATOR_CLI"] {
            return FileManager.default.isReadableFile(atPath: envPath) ? envPath : nil
        }
        let defaultPath = NSHomeDirectory() + "/Repos/claude-hibernator/cli.py"
        return FileManager.default.isReadableFile(atPath: defaultPath) ? defaultPath : nil
    }()

    private func runHibernatorCommand(_ arguments: [String]) async -> String? {
        guard let cliPath = Self.hibernatorCLI else { return nil }
        let parentDir = (cliPath as NSString).deletingLastPathComponent
        let allArgs = [cliPath] + arguments

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = allArgs
                process.environment = ProcessInfo.processInfo.environment
                process.environment?["PYTHONPATH"] = parentDir

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Tmux Discovery

    private func loadExistingSessions() {
        Task {
            let output = await TmuxHelpers.run(arguments: [
                "list-sessions", "-F", "#{session_name}"
            ])
            await MainActor.run {
                guard let output, !output.isEmpty else {
                    existingSessions = []
                    return
                }
                existingSessions = output
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty && !$0.hasPrefix("_ah_") }
                    .sorted()
            }
        }
    }
}

// MARK: - HibernatedSession Model

struct HibernatedSession: Identifiable {
    let id: Int
    let sessionName: String
    let workingDirectory: String
    let hibernatedAt: String

    var displayDate: String {
        // "2026-03-17T03:16:58.617202+00:00" -> "Mar 17 03:16"
        let raw = hibernatedAt.prefix(16).replacingOccurrences(of: "T", with: " ")
        return String(raw)
    }

    var shortDir: String {
        let path = workingDirectory
        if path.isEmpty || path == "/" { return "~" }
        return (path as NSString).lastPathComponent
    }

    static func parse(json: String) -> [HibernatedSession] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { dict in
            guard let id = dict["id"] as? Int,
                  let name = dict["session_name"] as? String,
                  let hibernatedAt = dict["hibernated_at"] as? String else {
                return nil
            }
            let workDir = dict["working_directory"] as? String ?? ""
            return HibernatedSession(
                id: id,
                sessionName: name,
                workingDirectory: workDir,
                hibernatedAt: hibernatedAt
            )
        }
    }
}
