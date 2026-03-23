import SwiftUI

/// Root view — sidebar + main content area.
struct FloatingPanelRootView: View {
    var store: NotificationStore
    @State private var activeTerminal: TerminalTarget? = nil
    @State private var showingSpeedrun: Bool = false

    struct TerminalTarget: Equatable {
        let target: String
        let machineHost: String?
    }

    enum MainPanel {
        case list
        case terminal(TerminalTarget)
        case speedrun
    }

    private var activePanel: MainPanel {
        if showingSpeedrun { return .speedrun }
        if let t = activeTerminal { return .terminal(t) }
        return .list
    }

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                SessionSidebarView(store: store, onSelectSession: { session in
                    selectSession(session)
                }, onReconnectSession: { session in
                    reconnectSession(session)
                })
                Divider()
            }
            mainContent
        }
        .frame(minWidth: store.sidebarVisible ? 560 : 380, minHeight: 300)
        // Hidden button for Cmd+\ sidebar toggle
        .background {
            Button("") { store.toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
                .hidden()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch activePanel {
        case .speedrun:
            SpeedrunView(store: store, onExit: {
                showingSpeedrun = false
                activeTerminal = nil
                store.stopSpeedrun()
            })
        case .terminal(let t):
            terminalMode(target: t.target, machineHost: t.machineHost)
        case .list:
            listMode
        }
    }

    private var listMode: some View {
        NotificationListView(
            store: store,
            onOpenTerminal: { notification in
                if let target = notification.tmuxPane ?? notification.tmuxSession {
                    activeTerminal = TerminalTarget(target: target, machineHost: nil)
                }
            },
            onSelectSession: { session in
                selectSession(session)
            },
            onStartSpeedrun: {
                store.startSpeedrun()
                showingSpeedrun = true
            }
        )
    }

    private func terminalMode(target: String, machineHost: String?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { activeTerminal = nil }) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(sessionName(for: target))
                    .font(.callout.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: startSpeedrun) {
                    Label("Speedrun", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(store.waitingCount > 0 ? .orange : .blue)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            TerminalContainerView(
                target: target,
                machineHost: machineHost,
                zoomLevel: store.zoomLevel
            )
            .id("\(machineHost ?? "local"):\(target)")
        }
    }

    private func startSpeedrun() {
        activeTerminal = nil
        store.startSpeedrun()
        showingSpeedrun = true
    }

    private func sessionName(for target: String) -> String {
        store.sessions.first(where: { $0.terminalTarget == target })?.displayName ?? target
    }

    private func selectSession(_ session: ClaudeSession) {
        showingSpeedrun = false
        store.stopSpeedrun()
        store.selectSession(session.id)
        if let target = session.terminalTarget {
            activeTerminal = TerminalTarget(target: target, machineHost: session.machineHost)
        }
    }

    /// Force-reconnect by clearing the terminal and re-opening after a tick.
    private func reconnectSession(_ session: ClaudeSession) {
        activeTerminal = nil
        store.selectSession(session.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let target = session.terminalTarget {
                activeTerminal = TerminalTarget(target: target, machineHost: session.machineHost)
            }
        }
    }
}
