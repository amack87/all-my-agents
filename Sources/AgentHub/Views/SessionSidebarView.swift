import SwiftUI

/// Left sidebar showing all active Claude Code sessions with status indicators.
struct SessionSidebarView: View {
    var store: NotificationStore
    var onSelectSession: (ClaudeSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            Divider()
            sessionList
        }
        .frame(width: 180)
        .background(.ultraThinMaterial)
        .sheet(isPresented: Binding(
            get: { store.showingAddSession },
            set: { store.showingAddSession = $0 }
        )) {
            AddSessionSheet(store: store, onSelectSession: onSelectSession)
        }
    }

    private var sidebarHeader: some View {
        HStack {
            Text("Sessions")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(store.sortedSessions.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button(action: { store.showingAddSession = true }) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Add session")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.sortedSessions.isEmpty {
                    emptyState
                } else {
                    ForEach(store.sortedSessions) { session in
                        SessionRowView(
                            session: session,
                            isActive: session.id == store.activeSessionID
                        )
                        .onTapGesture { onSelectSession(session) }
                        .contextMenu {
                            if session.terminalTarget != nil {
                                Button("Open Terminal") { onSelectSession(session) }
                            }
                            Divider()
                            Button("Remove from Sidebar", role: .destructive) {
                                store.hideSession(session)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No sessions")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

struct SessionRowView: View {
    let session: ClaudeSession
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.6), radius: statusGlow ? 3 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.agent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    /// Whether the dot should have a glow effect (active statuses only).
    private var statusGlow: Bool {
        session.status == .needsInput || session.status == .working
    }

    private var statusColor: Color {
        switch session.status {
        case .needsInput: return .orange
        case .working: return .green
        case .idle, .unknown: return idleFadingColor
        }
    }

    /// Blue (#6366F1) fading to dark over 4 hours based on last activity.
    private var idleFadingColor: Color {
        guard let activity = session.lastActivity else {
            return Color(red: 0.1, green: 0.1, blue: 0.18) // fully faded
        }
        let ageSec = Date().timeIntervalSince(activity)
        let fadeDuration: TimeInterval = 4 * 60 * 60 // 4 hours
        let t = min(max(ageSec / fadeDuration, 0), 1) // 0 = just now, 1 = 4h+ ago

        // Lerp from blue (99,102,241) to dark (26,26,46)
        let r = (99.0 + (26.0 - 99.0) * t) / 255.0
        let g = (102.0 + (26.0 - 102.0) * t) / 255.0
        let b = (241.0 + (46.0 - 241.0) * t) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
