import AppKit
import SwiftUI
import SwiftTerm

/// NSViewRepresentable wrapping a SwiftTerm LocalProcessTerminalView that attaches to tmux.
/// Uses `.id(target)` in the parent to force full recreation when the session target changes.
struct TerminalContainerView: NSViewRepresentable {
    let target: String
    var zoomLevel: CGFloat = 1.0
    var onDetached: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let terminalSession = TerminalSession(target: target)
        terminalSession.onProcessExited = {
            DispatchQueue.main.async {
                onDetached?()
            }
        }

        let fontSize = 13.0 * zoomLevel
        let terminalView = terminalSession.createTerminalView(fontSize: fontSize)

        // Store session in coordinator for cleanup
        context.coordinator.session = terminalSession
        context.coordinator.currentTarget = target
        context.coordinator.terminalView = terminalView
        context.coordinator.currentZoom = zoomLevel

        // Add local key event monitor for Cmd+V paste and Cmd+C copy
        context.coordinator.installKeyMonitor(for: terminalView)

        // Auto-focus the terminal once it's in the window hierarchy
        DispatchQueue.main.async { [weak terminalView] in
            guard let tv = terminalView, let window = tv.window else { return }
            window.makeFirstResponder(tv)
        }

        return terminalView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only apply zoom changes — nothing else.
        // IMPORTANT: Do NOT call makeFirstResponder here. updateNSView is called
        // on every SwiftUI re-render (every ~1s from session polling). Forcing
        // first responder can trigger a terminal relayout → SIGWINCH → tmux full
        // pane redraw, causing visible "scroll from top to bottom" flicker.
        if context.coordinator.currentZoom != zoomLevel {
            context.coordinator.currentZoom = zoomLevel
            if let tv = context.coordinator.terminalView {
                let fontSize = 13.0 * zoomLevel
                tv.font = FontFactory.terminalFont(size: fontSize)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeKeyMonitor()
        coordinator.session?.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var session: TerminalSession?
        var currentTarget: String?
        var currentZoom: CGFloat = 1.0
        weak var terminalView: LocalProcessTerminalView?
        private var keyMonitor: Any?
        private var flagsMonitor: Any?

        func installKeyMonitor(for view: LocalProcessTerminalView) {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
                guard let view, view.window?.firstResponder === view else { return event }
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "v":
                        // Paste from clipboard
                        if let text = NSPasteboard.general.string(forType: .string) {
                            let bytes = Array(text.utf8)
                            view.send(bytes)
                        }
                        return nil // consumed
                    case "c":
                        // Copy selection if any text is selected
                        if let selection = view.getSelection(), !selection.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selection, forType: .string)
                            return nil // consumed
                        }
                        // No selection — send Ctrl-C to terminal
                        return event
                    default:
                        return event
                    }
                }
                return event
            }

            // Hold Option to bypass tmux mouse reporting and enable native text selection.
            // When Option is released, mouse events go back to tmux.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak view] event in
                guard let view else { return event }
                let optionHeld = event.modifierFlags.contains(.option)
                view.allowMouseReporting = !optionHeld
                return event
            }
        }

        func removeKeyMonitor() {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
        }

        deinit {
            removeKeyMonitor()
        }
    }
}
