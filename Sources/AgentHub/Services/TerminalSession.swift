import AppKit
import SwiftTerm

/// Manages a SwiftTerm LocalProcessTerminalView that attaches to a tmux session/pane.
/// Handles process lifecycle, detach, and termination.
final class TerminalSession {
    let target: String  // tmux pane ID ("%3") or session name
    private(set) var terminalView: LocalProcessTerminalView?
    private var scrollMonitor: Any?

    var onProcessExited: (() -> Void)?

    init(target: String) {
        self.target = target
    }

    /// Create and return the terminal view, attaching to the tmux target.
    func createTerminalView(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600), fontSize: CGFloat = 13) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: frame)
        view.processDelegate = self

        view.font = FontFactory.terminalFont(size: fontSize)
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor

        let tmux = TmuxHelpers.tmuxPath()

        // Use attach-session to connect as an additional client to the existing
        // session. Multiple clients can attach to the same session; tmux handles
        // this natively without creating session groups.
        //
        // Previously we used `new-session -t` to create grouped sessions, but
        // this triggers a use-after-free crash in tmux 3.6a's
        // server_destroy_session_group → notify_session → cmd_find_from_nothing
        // path when the base session's last window is destroyed, taking down the
        // entire tmux server.
        //
        // We use tmux-attach-helper because SwiftTerm's Subprocess path
        // (Swift 6.1+) uses POSIX_SPAWN_SETSID without TIOCSCTTY, so the child
        // has no controlling terminal. The helper calls setsid() + TIOCSCTTY
        // to establish one before exec'ing tmux.
        let helper = Self.helperPath()

        if target.hasPrefix("%") {
            // Pane ID: resolve to session name, then attach.
            view.startProcess(
                executable: "/bin/sh",
                args: ["-c", "SESSION=$(\(tmux) display-message -t \(target) -p '#{session_name}') && exec \(helper) \(tmux) attach-session -t \"$SESSION\""],
                environment: Self.terminalEnvironment(),
                execName: "sh"
            )
        } else {
            view.startProcess(
                executable: helper,
                args: [tmux, "attach-session", "-t", target],
                environment: Self.terminalEnvironment(),
                execName: "tmux-attach-helper"
            )
        }

        terminalView = view
        scrollMonitor = installScrollInterceptor(on: view)
        return view
    }

    /// Detach from the tmux session by asking the server to detach this client.
    /// Uses `tmux detach-client -t <target>` which works regardless of the
    /// user's configured prefix key.
    func detach() {
        guard terminalView != nil else { return }
        let sessionTarget = target
        Task {
            _ = await TmuxHelpers.run(arguments: ["detach-client", "-t", sessionTarget])
        }
    }

    /// Terminate by detaching — the tmux client process exits, leaving the
    /// base session alive. No grouped session to clean up.
    func terminate() {
        onProcessExited = nil  // prevent stale callback after deliberate teardown
        detach()
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        terminalView = nil
    }

    // MARK: - Helper Path

    /// Resolve path to tmux-attach-helper bundled alongside the main executable.
    private static func helperPath() -> String {
        if let execURL = Bundle.main.executableURL {
            let helper = execURL.deletingLastPathComponent().appendingPathComponent("tmux-attach-helper").path
            if FileManager.default.isExecutableFile(atPath: helper) {
                return helper
            }
        }
        return "tmux-attach-helper"
    }

    /// Build environment for the terminal process.
    private static func terminalEnvironment() -> [String] {
        var env = TmuxHelpers.tmuxEnvironment()
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        return env.map { "\($0.key)=\($0.value)" }
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal handles this automatically
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Could update panel title if desired
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Not needed
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onProcessExited?()
    }
}
