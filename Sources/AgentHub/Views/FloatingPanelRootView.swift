import SwiftUI

/// Root view — sidebar + main content area.
struct FloatingPanelRootView: View {
    var store: NotificationStore
    @State private var activeTerminal: TerminalTarget? = nil
    @State private var showingSpeedrun: Bool = false
    @State private var showKillAlert = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showSettings = false

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

    private var currentSession: ClaudeSession? {
        guard let t = activeTerminal else { return nil }
        return store.sessions.first(where: { $0.terminalTarget == t.target })
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
        .background {
            Button("") { store.toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
                .hidden()
        }
        .alert("Kill Session", isPresented: $showKillAlert, presenting: currentSession) { session in
            Button("Kill", role: .destructive) { killSession(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Kill tmux session \"\(session.displayName)\"? This terminates the agent.")
        }
        .alert("Rename Session", isPresented: $showRenameAlert, presenting: currentSession) { session in
            TextField("New name", text: $renameText)
            Button("Rename") { renameSession(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Rename \"\(session.displayName)\" to:")
        }
        .sheet(isPresented: Binding(
            get: { store.showSettings },
            set: { store.showSettings = $0 }
        )) {
            SettingsView(store: store)
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
            HStack(spacing: 6) {
                Button(action: { activeTerminal = nil }) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text(sessionName(for: target))
                    .font(.callout.bold())
                    .foregroundStyle(.primary)

                Spacer()

                ControlGroup {
                    if currentSession?.tmuxSession != nil {
                        Button(action: { reconnect(host: machineHost, target: target) }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Reconnect")

                        Button(action: {
                            renameText = currentSession?.displayName ?? ""
                            showRenameAlert = true
                        }) {
                            Image(systemName: "pencil")
                        }
                        .help("Rename Session")

                        Button(action: { showKillAlert = true }) {
                            Image(systemName: "xmark.square")
                                .foregroundStyle(.red)
                        }
                        .help("Kill Session")
                    }
                }
                .controlSize(.small)

                Button(action: startSpeedrun) {
                    Label("Speedrun", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(store.waitingCount > 0 ? .orange : .blue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            TerminalContainerView(
                target: target,
                machineHost: machineHost,
                meshServerURL: store.meshServerURL,
                zoomLevel: store.zoomLevel,
                onDetached: { activeTerminal = nil }
            )
            .id("\(machineHost ?? "local"):\(target)")
        }
    }

    private func renameSession(_ session: ClaudeSession) {
        guard let tmuxSession = session.tmuxSession, !renameText.isEmpty else { return }
        Task {
            _ = await TmuxHelpers.renameSession(currentName: tmuxSession, newName: renameText)
            await MainActor.run { store.hideSession(session) }
        }
    }

    private func killSession(_ session: ClaudeSession) {
        guard let name = session.tmuxSession else { return }
        Task {
            _ = await TmuxHelpers.killSession(named: name)
            await MainActor.run {
                store.hideSession(session)
                activeTerminal = nil
            }
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

    private func reconnect(host: String?, target: String) {
        activeTerminal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            activeTerminal = TerminalTarget(target: target, machineHost: host)
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
