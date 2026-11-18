import Foundation
import Observation

/// Owns the hibernation/backup settings and runs the hibernator CLI.
///
/// These settings used to live on the web server (`GET`/`PUT /api/settings`
/// and `POST /api/backup/run`). That server has never had those routes and
/// has no hibernation concept at all, so the Settings pane sat on "Loading
/// server settings…" forever and "Backup Now" could never work. The
/// hibernator CLI on this machine can do both jobs (`backup --all` and
/// `hibernate <name>`), so the app owns the settings and drives the CLI.
@MainActor
@Observable
final class BackupService {
    struct Settings: Codable, Equatable {
        /// Take a periodic context snapshot of every active session.
        var enabled: Bool
        /// How many minutes between snapshots.
        var intervalMinutes: Int
        /// Hibernate idle sessions when the app quits.
        var hibernateOnShutdown: Bool

        static let defaults = Settings(
            enabled: true,
            intervalMinutes: 60,
            hibernateOnShutdown: true
        )
    }

    static let shared = BackupService()

    private static let storageKey = "allmyagents-backup-settings"

    var settings: Settings
    var isBackingUp = false
    var lastStatus: String?

    private let defaults: UserDefaults
    private var timerTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let loaded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = loaded
        } else {
            self.settings = .defaults
        }
    }

    // MARK: - Settings

    /// Change the settings, persist them, and re-arm the timer.
    func update(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        next.intervalMinutes = min(max(next.intervalMinutes, 1), 1440)
        settings = next
        persist()
        reschedule()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Periodic backups

    /// Start the periodic backup timer. Called once at app launch.
    func start() {
        reschedule()
    }

    private func reschedule() {
        timerTask?.cancel()
        timerTask = nil
        guard settings.enabled else { return }

        let minutes = UInt64(min(max(settings.intervalMinutes, 1), 1440))
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: minutes * 60 * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.backupNow()
            }
        }
    }

    // MARK: - Actions

    /// Take a context snapshot of every active session. Returns a status
    /// message suitable for showing in the UI.
    @discardableResult
    func backupNow() async -> String {
        guard HibernatorService.isAvailable else {
            lastStatus = "Hibernator CLI not found — set HIBERNATOR_CLI"
            return lastStatus ?? ""
        }

        isBackingUp = true
        defer { isBackingUp = false }

        let message: String
        if let result = await HibernatorService.run(["backup", "--all"]) {
            if result.status == 0 {
                message = result.output.flatMap { $0.isEmpty ? nil : $0 } ?? "Backup complete"
            } else {
                message = result.output.flatMap { $0.isEmpty ? nil : $0 } ?? "Backup failed"
            }
        } else {
            message = "Could not run the hibernator CLI"
        }

        lastStatus = message
        return message
    }

    /// Hibernate the given idle sessions. Used when the app quits.
    /// Before hibernating, discovers Claude session IDs so they can be used
    /// for faithful restoration via `claude --resume <uuid>`.
    @discardableResult
    func hibernateOnQuit(sessionNames: [String]) -> [String] {
        guard settings.hibernateOnShutdown, HibernatorService.isAvailable else { return [] }

        // Discover Claude session IDs before hibernating
        var sessionIdMap: [String: String] = [:]  // sessionName -> sessionId
        for name in sessionNames {
            if let sessionId = ClaudeSessionIndex.sessionId(forTmuxSession: name) {
                sessionIdMap[name] = sessionId
            }
        }

        // If we found session IDs, write them to a sidecar file for the restore path
        if !sessionIdMap.isEmpty {
            writeSessionIdMap(sessionIdMap)
        }

        return HibernatorService.hibernateSynchronously(sessionNames: sessionNames)
    }

    /// Path to the sidecar file that stores session IDs for hibernated sessions.
    private var sessionIdMapPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AllMyAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hibernated-session-ids.json")
    }

    /// Write session IDs to a sidecar file so the restore path can find them.
    private func writeSessionIdMap(_ map: [String: String]) {
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: sessionIdMapPath)
        } catch {
            // Best effort - the restore will fall back to context pipe
        }
    }

    /// Read session IDs from the sidecar file.
    func readSessionIdMap() -> [String: String] {
        guard let data = try? Data(contentsOf: sessionIdMapPath),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    /// Clear the session ID map (called after successful restore).
    func clearSessionIdMap() {
        try? FileManager.default.removeItem(at: sessionIdMapPath)
    }
}
