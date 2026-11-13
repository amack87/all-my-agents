import Foundation

/// Locates and drives the tmux-agent-hibernator CLI.
///
/// The web server has no hibernation concept: it has never had an
/// `/api/settings` or an `/api/backup/run` route. The hibernator CLI is
/// therefore the only thing that can back a session up or put it to sleep,
/// and both the Add Session sheet and the Settings pane go through here.
enum HibernatorService {
    /// Path to the hibernator CLI. Set HIBERNATOR_CLI or probe the known
    /// install locations (the repo was renamed claude-hibernator →
    /// tmux-agent-hibernator). Nil when no CLI is installed.
    static let cliPath: String? = {
        if let envPath = ProcessInfo.processInfo.environment["HIBERNATOR_CLI"] {
            return FileManager.default.isReadableFile(atPath: envPath) ? envPath : nil
        }
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Repos/tmux-agent-hibernator/cli.py",
            home + "/Repos/claude-hibernator/cli.py",
            home + "/.local/bin/claude-hibernator/cli.py",
            home + "/claude-hibernator/cli.py",
        ]
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { cliPath != nil }

    /// Result of one CLI invocation: the exit status and whatever it printed.
    struct Result {
        let status: Int32
        let output: String?
    }

    /// Run a hibernator subcommand. Nil when the CLI is missing or the
    /// process could not be started at all.
    static func run(_ arguments: [String]) async -> Result? {
        guard let cliPath else { return nil }
        let parentDir = (cliPath as NSString).deletingLastPathComponent

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [cliPath] + arguments
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
                    continuation.resume(returning: Result(status: process.terminationStatus, output: output))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Hibernate sessions on app termination, where there is no time to await
    /// anything. Best effort: each session gets at most `timeout` seconds, and
    /// a session that does not finish is simply left running.
    @discardableResult
    static func hibernateSynchronously(
        sessionNames: [String],
        timeout: TimeInterval = 2.0
    ) -> [String] {
        guard let cliPath, !sessionNames.isEmpty else { return [] }
        let parentDir = (cliPath as NSString).deletingLastPathComponent

        let lock = NSLock()
        var hibernated: [String] = []
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { semaphore.signal() }
            for name in sessionNames {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [cliPath, "hibernate", name]
                process.environment = ProcessInfo.processInfo.environment
                process.environment?["PYTHONPATH"] = parentDir
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        lock.lock()
                        hibernated.append(name)
                        lock.unlock()
                    }
                } catch {
                    // A session that cannot be hibernated is left as it is.
                }
            }
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        let result = hibernated
        lock.unlock()
        return result
    }
}
