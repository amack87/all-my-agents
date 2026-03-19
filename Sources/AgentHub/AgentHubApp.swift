import AppKit
import SwiftUI

@main
struct AllMyAgentsLauncher {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular) // Dock icon + app switcher
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var server: WebhookServer?
    private var sessionMonitor: SessionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        // Set up status bar item (quick toggle)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "All My Agents")
            button.action = #selector(toggleWindow)
            button.target = self
        }

        // Set up main window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "All My Agents"
        window.minSize = NSSize(width: 560, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("AllMyAgentsMainWindow")

        window.contentView = NSHostingView(
            rootView: FloatingPanelRootView(store: NotificationStore.shared)
        )

        window.makeKeyAndOrderFront(nil)

        // Start webhook server
        do {
            server = try WebhookServer(port: 9876)
            server?.start()
        } catch {
            print("[AllMyAgents] Failed to start server: \(error)")
        }

        // Start session monitor (process-based discovery)
        sessionMonitor = SessionMonitor(store: NotificationStore.shared)
        sessionMonitor?.start()

        // Update badge when store changes
        let store = NotificationStore.shared
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateBadge(waitingCount: store.waitingCount)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    @objc private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateBadge(waitingCount: Int) {
        guard let button = statusItem.button else { return }
        if waitingCount > 0 {
            button.title = " \(waitingCount)"
        } else {
            button.title = ""
        }

        // Also update dock badge
        NSApp.dockTile.badgeLabel = waitingCount > 0 ? "\(waitingCount)" : nil
    }

    // MARK: - Main Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About All My Agents", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit All My Agents", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // View menu (zoom controls)
        let viewMenu = NSMenu(title: "View")
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)
        let zoomResetItem = NSMenuItem(title: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
        zoomResetItem.target = self
        viewMenu.addItem(zoomResetItem)

        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Zoom

    @objc private func zoomIn() {
        NotificationStore.shared.adjustZoom(by: 1)
    }

    @objc private func zoomOut() {
        NotificationStore.shared.adjustZoom(by: -1)
    }

    @objc private func zoomReset() {
        NotificationStore.shared.resetZoom()
    }
}
