import Foundation

/// Helpers for interacting with tmux — socket path, environment, command execution.
/// Uses DispatchQueue + readDataToEndOfFile + waitUntilExit to avoid Swift concurrency deadlocks.
enum TmuxHelpers {

    /// The tmux socket directory (e.g. /private/tmp/tmux-501)
    static var socketDir: String {
        let uid = getuid()
        return "/private/tmp/tmux-\(uid)"
    }

    /// Environment variables needed for tmux commands.
    /// Does NOT set TMUX_TMPDIR — tmux already knows its socket location.
    /// Setting it would cause a doubled path (e.g. tmux-501/tmux-501).
    static func tmuxEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    /// Resolve the tmux binary path.
    static func tmuxPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "tmux"
    }

    /// Run a tmux command asynchronously and return stdout.
    /// Uses DispatchQueue.global to avoid blocking Swift concurrency cooperative threads.
    static func run(arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: tmuxPath())
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.environment = tmuxEnvironment()

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output)
            }
        }
    }
}
