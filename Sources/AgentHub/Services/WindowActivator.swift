import AppKit
import AXSwift

enum WindowActivator {

    enum ActivationError: Error, LocalizedError {
        case accessibilityDenied
        case appNotFound(pid: pid_t)
        case windowNotFound(title: String)

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission denied"
            case .appNotFound(let pid):
                return "Application not found for PID \(pid)"
            case .windowNotFound(let title):
                return "Window not found matching '\(title)'"
            }
        }
    }

    /// Call this only when you want to show the system permission dialog (e.g. "Grant Accessibility" button).
    /// Use hasAccessibilityPermission for checks without prompting.
    static func requestAccessibilityPermission() -> Bool {
        UIElement.isProcessTrusted(withPrompt: true)
    }

    static func activate(notification: AgentNotification) throws {
        guard UIElement.isProcessTrusted(withPrompt: false) else {
            throw ActivationError.accessibilityDenied
        }

        guard let runningApp = findRunningApp(pid: notification.pid, bundleID: notification.appBundleID) else {
            throw ActivationError.appNotFound(pid: notification.pid)
        }

        guard let axApp = Application(runningApp) else {
            throw ActivationError.appNotFound(pid: notification.pid)
        }

        if let window = try findWindow(in: axApp, matchingTitle: notification.windowTitle) {
            let isMinimized: Bool? = try window.attribute(.minimized)
            if isMinimized == true {
                try window.setAttribute(.minimized, value: false)
            }
            try window.performAction(.raise)
        }

        runningApp.activate()
    }

    static var hasAccessibilityPermission: Bool {
        UIElement.isProcessTrusted(withPrompt: false)
    }

    private static func findRunningApp(pid: pid_t, bundleID: String) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }
    }

    private static func findWindow(in app: Application, matchingTitle title: String) throws -> UIElement? {
        guard let windows = try app.windows() else { return nil }

        // Exact match first
        for window in windows {
            let windowTitle: String? = try window.attribute(.title)
            if windowTitle == title { return window }
        }

        // Substring match fallback
        for window in windows {
            let windowTitle: String? = try window.attribute(.title)
            if let windowTitle, windowTitle.contains(title) { return window }
        }

        return nil
    }
}
