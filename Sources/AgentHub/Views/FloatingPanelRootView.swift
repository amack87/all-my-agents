import SwiftUI

/// Root view — sidebar + main content area.
struct FloatingPanelRootView: View {
    var store: NotificationStore
    @State private var activeTerminalTarget: String? = nil
    @State private var showingSpeedrun: Bool = false

    enum MainPanel {
        case list
        case terminal(String)
        case speedrun
    }

    private var activePanel: MainPanel {
        if showingSpeedrun { return .speedrun }
        if let target = activeTerminalTarget { return .terminal(target) }
        return .list
    }

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                SessionSidebarView(store: store, onSelectSession: { session in
                    selectSession(session)
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
                activeTerminalTarget = nil
                store.stopSpeedrun()
            })
        case .terminal(let target):
            terminalMode(target: target)
        case .list:
            listMode
        }
    }

    private var listMode: some View {
        NotificationListView(
            store: store,
            onOpenTerminal: { notification in
                if let target = notification.tmuxPane ?? notification.tmuxSession {
                    activeTerminalTarget = target
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

    private func terminalMode(target: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { activeTerminalTarget = nil }) {
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
            TerminalContainerView(target: target, zoomLevel: store.zoomLevel)
                .id(target)
        }
    }

    private func startSpeedrun() {
        activeTerminalTarget = nil
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
            activeTerminalTarget = target
        }
    }
}
