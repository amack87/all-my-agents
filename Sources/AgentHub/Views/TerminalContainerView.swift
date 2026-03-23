import AppKit
import SwiftUI
import SwiftTerm

/// NSViewRepresentable wrapping a SwiftTerm terminal that attaches to tmux.
/// For local sessions: uses LocalProcessTerminalView with direct tmux attach.
/// For remote sessions: uses base TerminalView with WebSocket proxy through the web server.
/// Uses `.id(target)` in the parent to force full recreation when the session target changes.
struct TerminalContainerView: NSViewRepresentable {
    let target: String
    var machineHost: String? = nil
    var zoomLevel: CGFloat = 1.0
    var onDetached: (() -> Void)? = nil

    private var isRemote: Bool {
        guard let host = machineHost else { return false }
        return host != "local"
    }

    func makeNSView(context: Context) -> NSView {
        let fontSize = 13.0 * zoomLevel
        context.coordinator.currentZoom = zoomLevel

        if isRemote, let host = machineHost {
            return makeRemoteView(host: host, fontSize: fontSize, context: context)
        } else {
            return makeLocalView(fontSize: fontSize, context: context)
        }
    }

    private func makeLocalView(fontSize: CGFloat, context: Context) -> NSView {
        let terminalSession = TerminalSession(target: target)
        terminalSession.onProcessExited = {
            DispatchQueue.main.async { onDetached?() }
        }

        let terminalView = terminalSession.createTerminalView(fontSize: fontSize)

        context.coordinator.localSession = terminalSession
        context.coordinator.currentTarget = target
        context.coordinator.localTerminalView = terminalView
        context.coordinator.installKeyMonitor(for: terminalView)

        DispatchQueue.main.async { [weak terminalView] in
            guard let tv = terminalView, let window = tv.window else { return }
            window.makeFirstResponder(tv)
        }

        return terminalView
    }

    private func makeRemoteView(host: String, fontSize: CGFloat, context: Context) -> NSView {
        let wsSession = WebSocketTerminalSession(machineHost: host, target: target)
        wsSession.onDisconnected = {
            DispatchQueue.main.async { onDetached?() }
        }

        let terminalView = wsSession.createTerminalView(fontSize: fontSize)

        context.coordinator.wsSession = wsSession
        context.coordinator.currentTarget = target
        context.coordinator.remoteTerminalView = terminalView
        context.coordinator.installKeyMonitorForRemote(for: terminalView)

        DispatchQueue.main.async { [weak terminalView] in
            guard let tv = terminalView, let window = tv.window else { return }
            window.makeFirstResponder(tv)
        }

        return terminalView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only apply zoom changes. Do NOT call makeFirstResponder — see earlier comments.
        if context.coordinator.currentZoom != zoomLevel {
            context.coordinator.currentZoom = zoomLevel
            let fontSize = 13.0 * zoomLevel
            if let tv = context.coordinator.localTerminalView {
                tv.font = FontFactory.terminalFont(size: fontSize)
            }
            if let tv = context.coordinator.remoteTerminalView {
                tv.font = FontFactory.terminalFont(size: fontSize)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeKeyMonitor()
        coordinator.localSession?.terminate()
        coordinator.wsSession?.disconnect()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var localSession: TerminalSession?
        var wsSession: WebSocketTerminalSession?
        var currentTarget: String?
        var currentZoom: CGFloat = 1.0
        weak var localTerminalView: LocalProcessTerminalView?
        weak var remoteTerminalView: TerminalView?
        private var keyMonitor: Any?
        private var flagsMonitor: Any?

        /// Key monitor for local sessions (LocalProcessTerminalView).
        func installKeyMonitor(for view: LocalProcessTerminalView) {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
                guard let view, view.window?.firstResponder === view else { return event }
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "v":
                        if let text = NSPasteboard.general.string(forType: .string) {
                            view.send(Array(text.utf8))
                        }
                        return nil
                    case "c":
                        if let selection = view.getSelection(), !selection.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selection, forType: .string)
                            return nil
                        }
                        return event
                    default:
                        return event
                    }
                }
                return event
            }

            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak view] event in
                guard let view else { return event }
                view.allowMouseReporting = !event.modifierFlags.contains(.option)
                return event
            }
        }

        /// Key monitor for remote sessions (base TerminalView).
        func installKeyMonitorForRemote(for view: TerminalView) {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
                guard let view, view.window?.firstResponder === view else { return event }
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "v":
                        if let text = NSPasteboard.general.string(forType: .string) {
                            view.send(Array(text.utf8))
                        }
                        return nil
                    case "c":
                        if let selection = view.getSelection(), !selection.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selection, forType: .string)
                            return nil
                        }
                        return event
                    default:
                        return event
                    }
                }
                return event
            }

            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak view] event in
                guard let view else { return event }
                view.allowMouseReporting = !event.modifierFlags.contains(.option)
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
