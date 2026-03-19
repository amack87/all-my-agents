import AppKit

/// Floating NSPanel that stays above other windows, is resizable/movable, and persists its frame.
final class FloatingPanel: NSPanel {
    private static let frameSaveKey = "AllMyAgentsPanelFrame"

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        title = "All My Agents"
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .windowBackgroundColor
        minSize = NSSize(width: 560, height: 300)

        // Restore saved frame
        setFrameUsingName(Self.frameSaveKey)
    }

    override func close() {
        saveFrame(usingName: Self.frameSaveKey)
        orderOut(nil)
    }

    func toggle(near statusItemButton: NSStatusBarButton?) {
        if isVisible {
            close()
        } else {
            show(near: statusItemButton)
        }
    }

    func show(near statusItemButton: NSStatusBarButton?) {
        // If we have a saved position, use it; otherwise position near the status item
        if !setFrameUsingName(Self.frameSaveKey) {
            positionNearStatusItem(statusItemButton)
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionNearStatusItem(_ button: NSStatusBarButton?) {
        guard let button = button,
              let screen = NSScreen.main else { return }

        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let panelWidth = frame.width
        let panelHeight = frame.height

        let x = min(buttonRect.midX - panelWidth / 2, screen.visibleFrame.maxX - panelWidth)
        let y = buttonRect.minY - panelHeight - 4

        setFrameOrigin(NSPoint(x: max(x, screen.visibleFrame.minX), y: y))
    }

    /// Animate to a new size (used when entering/exiting terminal mode)
    func animateResize(to size: NSSize) {
        let currentFrame = frame
        let newOrigin = NSPoint(
            x: currentFrame.midX - size.width / 2,
            y: currentFrame.maxY - size.height
        )
        let newFrame = NSRect(origin: newOrigin, size: size)
        setFrame(newFrame, display: true, animate: true)
    }

    override func resignKey() {
        super.resignKey()
        saveFrame(usingName: Self.frameSaveKey)
    }
}
