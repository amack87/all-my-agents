import SwiftUI

struct NotificationListView: View {
    var store: NotificationStore
    var onOpenTerminal: ((AgentNotification) -> Void)? = nil
    var onSelectSession: ((ClaudeSession) -> Void)? = nil
    var onStartSpeedrun: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            sessionContent
            Divider()
            footerView
        }
        .frame(minWidth: 380)
        .frame(minHeight: 80, maxHeight: .infinity)
    }

    private var headerView: some View {
        HStack {
            Label("All My Agents", systemImage: "cpu")
                .font(.headline)
            Spacer()
            if store.waitingCount > 0 {
                Text("\(store.waitingCount) waiting")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let onStartSpeedrun, !store.notifications.isEmpty {
                Button("Speedrun") { onStartSpeedrun() }
                    .buttonStyle(.borderedProminent)
                    .tint(store.waitingCount > 0 ? .orange : .blue)
                    .font(.caption)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Session Content

    private var sessionContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                trackedSection
                availableSection
            }
        }
    }

    // MARK: - Tracked Sessions

    private var trackedSection: some View {
        Section {
            if store.sortedSessions.isEmpty {
                emptyTrackedView
            } else {
                ForEach(store.sortedSessions) { session in
                    TrackedSessionRow(session: session)
                        .onTapGesture {
                            if let onSelectSession {
                                onSelectSession(session)
                            } else if session.terminalTarget != nil,
                                      let notification = notificationFor(session) {
                                onOpenTerminal?(notification)
                            }
                        }
                        .contextMenu {
                            if session.terminalTarget != nil {
                                Button("Open Terminal") {
                                    onSelectSession?(session)
                                }
                            }
                            Divider()
                            Button("Remove from Tracked", role: .destructive) {
                                store.hideSession(session)
                            }
                        }
                    Divider().padding(.leading, 40)
                }
            }
        } header: {
            sectionHeader("Tracked Sessions", count: store.sortedSessions.count)
        }
    }

    private var emptyTrackedView: some View {
        HStack {
            Image(systemName: "tray")
                .foregroundStyle(.tertiary)
            Text("No tracked sessions")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Available Sessions

    private var availableSection: some View {
        Section {
            if store.availableSessions.isEmpty {
                emptyAvailableView
            } else {
                ForEach(store.availableSessions) { session in
                    AvailableSessionRow(session: session, onAdd: {
                        let name = session.tmuxSession ?? session.displayName
                        store.unhideSession(named: name)
                    })
                    Divider().padding(.leading, 40)
                }
            }
        } header: {
            sectionHeader("Available Sessions", count: store.availableSessions.count)
                .padding(.top, 4)
        }
    }

    private var emptyAvailableView: some View {
        HStack {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green.opacity(0.6))
            Text("All sessions tracked")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("Listening on :9876")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if !WindowActivator.hasAccessibilityPermission {
                Button("Grant Accessibility") {
                    _ = WindowActivator.requestAccessibilityPermission()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func notificationFor(_ session: ClaudeSession) -> AgentNotification? {
        let target = session.terminalTarget
        return store.notifications.first {
            $0.tmuxPane == target || $0.tmuxSession == session.tmuxSession
        }
    }
}

// MARK: - Tracked Session Row

private struct TrackedSessionRow: View {
    let session: ClaudeSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let path = session.projectPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(statusLabelColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch session.status {
        case .needsInput: return .orange
        case .working: return .green
        case .idle: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .needsInput: return "needs input"
        case .working: return "working"
        case .idle: return "idle"
        case .unknown: return ""
        }
    }

    private var statusLabelColor: Color {
        switch session.status {
        case .needsInput: return .orange
        case .working: return .green
        case .idle: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }
}

// MARK: - Available Session Row

private struct AvailableSessionRow: View {
    let session: ClaudeSession
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)

            Text(session.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus.circle")
                    .font(.callout)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.borderless)
            .help("Track this session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
