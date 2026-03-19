import AppKit
import SwiftTerm

/// Installs a local event monitor that intercepts scroll wheel events on the given
/// terminal view and forwards them as mouse escape sequences when tmux mouse mode
/// is active. Returns the monitor object (must be retained to keep active).
///
/// SwiftTerm's `scrollWheel` is not `open`, so we can't override it via subclass.
/// Instead, this monitor intercepts scroll events before SwiftTerm processes them.
func installScrollInterceptor(on terminalView: LocalProcessTerminalView) -> Any? {
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        guard event.deltaY != 0 else { return event }

        // Only intercept if this event targets our terminal view
        guard let targetView = event.window?.contentView?.hitTest(
            event.window!.contentView!.convert(event.locationInWindow, from: nil)
        ) else { return event }

        // Check if the target is our terminal view or a descendant of it
        var view: NSView? = targetView
        var isOurTerminal = false
        while let v = view {
            if v === terminalView { isOurTerminal = true; break }
            view = v.superview
        }
        guard isOurTerminal else { return event }

        // Only intercept when mouse reporting is active
        guard terminalView.terminal.mouseMode != .off else { return event }

        // Send scroll as mouse button 64 (up) or 65 (down)
        let lines = max(1, Int(abs(event.deltaY)))
        let button: Int = event.deltaY > 0 ? 64 : 65

        let cols = max(1, CGFloat(terminalView.terminal.cols))
        let rows = max(1, CGFloat(terminalView.terminal.rows))
        let cellWidth = terminalView.bounds.width / cols
        let cellHeight = terminalView.bounds.height / rows

        let loc = terminalView.convert(event.locationInWindow, from: nil)
        let col = Int(loc.x / cellWidth)
        let row = Int((terminalView.bounds.height - loc.y) / cellHeight)

        for _ in 0..<lines {
            terminalView.terminal.sendEvent(buttonFlags: button, x: col, y: row, pixelX: 0, pixelY: 0)
        }

        // Consume the event so SwiftTerm doesn't scroll its buffer
        return nil
    }
    return monitor
}
