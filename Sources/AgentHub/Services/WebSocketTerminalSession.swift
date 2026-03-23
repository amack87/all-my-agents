import AppKit
import SwiftTerm
import Foundation

/// Manages a SwiftTerm TerminalView connected to a remote tmux session via the
/// All My Agents web server's WebSocket proxy. Used for sessions on remote machines.
final class WebSocketTerminalSession: NSObject {
    let machineHost: String  // e.g. "100.64.1.5:3456"
    let target: String       // tmux session name or pane ID
    private(set) var terminalView: TerminalView?
    private var wsTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var scrollMonitor: Any?

    var onDisconnected: (() -> Void)?

    init(machineHost: String, target: String) {
        self.machineHost = machineHost
        self.target = target
    }

    /// Create the terminal view and connect via WebSocket.
    func createTerminalView(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600), fontSize: CGFloat = 13) -> TerminalView {
        let view = TerminalView(frame: frame)
        view.terminalDelegate = self

        view.font = FontFactory.terminalFont(size: fontSize)
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor

        terminalView = view

        // Connect WebSocket
        let encodedHost = machineHost.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? machineHost
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        let wsURL = URL(string: "ws://localhost:3456/ws/proxy/\(encodedHost)/\(encodedTarget)")!

        urlSession = URLSession(configuration: .default)
        wsTask = urlSession!.webSocketTask(with: wsURL)
        wsTask!.resume()

        // Start receive loop (messages are buffered by URLSession until open)
        receiveMessage()

        // Send initial resize after the view is in the window hierarchy and has a real
        // size. The web server's protocol requires the first message to be a resize
        // (it spawns the PTY on the first resize). We delay briefly so the view gets
        // laid out with actual dimensions instead of -2/0.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak view] in
            guard let self, let view = view else { return }
            let cols = max(view.getTerminal().cols, 80)
            let rows = max(view.getTerminal().rows, 24)
            self.sendJSON(["type": "resize", "cols": cols, "rows": rows])
        }

        return view
    }

    /// Disconnect and clean up.
    func disconnect() {
        onDisconnected = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        terminalView = nil
    }

    // MARK: - WebSocket I/O

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        wsTask?.send(.string(str)) { _ in }
    }

    private func receiveMessage() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessage()

            case .failure:
                DispatchQueue.main.async {
                    self.terminalView?.feed(text: "\r\n[Remote disconnected]\r\n")
                    self.onDisconnected?()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "output":
            if let output = json["data"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.terminalView?.feed(text: output)
                }
            }
        case "exit":
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.feed(text: "\r\n[Session ended]\r\n")
                self?.onDisconnected?()
            }
        default:
            break
        }
    }
}

// MARK: - TerminalViewDelegate

extension WebSocketTerminalSession: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sendJSON(["type": "resize", "cols": newCols, "rows": newRows])
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let str = String(bytes: data, encoding: .utf8) ?? ""
        sendJSON(["type": "input", "data": str])
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}
