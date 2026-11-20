import SwiftUI

/// Left sidebar showing all active Claude Code sessions with status indicators.
/// Layout follows the persisted manual order: collapsible groups (reorderable
/// via handle drag) in their stored sequence, then the ungrouped region,
/// then a trailing drop zone that appends to the end.
struct SessionSidebarView: View {
    var store: NotificationStore
    var onSelectSession: (ClaudeSession) -> Void
    var onReconnectSession: ((ClaudeSession) -> Void)? = nil

    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var sessionToRename: ClaudeSession? = nil
    @State private var showKillAlert = false
    @State private var sessionToKill: ClaudeSession? = nil
    @State private var showGroupAlert = false
    @State private var newGroupName = ""
    @State private var sessionForGroup: ClaudeSession? = nil
    @State private var showRenameGroupAlert = false
    @State private var renameGroupText = ""
    @State private var groupToRename: String? = nil
    @State private var trailingTargeted = false
    /// The sidebar width when the current resize drag began, so the drag
    /// tracks the pointer rather than compounding on itself.
    @State private var resizeStartWidth: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            Divider()
            machineFilterBar
            sessionList
        }
        .frame(width: store.sidebarWidth)
        .overlay(alignment: .trailing) { resizeHandle }
        .background(.ultraThinMaterial)
        .sheet(isPresented: Binding(
            get: { store.showingAddSession },
            set: { store.showingAddSession = $0 }
        )) {
            AddSessionSheet(store: store, onSelectSession: onSelectSession)
        }
        .alert("Rename Session", isPresented: $showRenameAlert, presenting: sessionToRename) { session in
            TextField("New name", text: $renameText)
            Button("Rename") {
                renameSession(session, to: renameText)
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Rename \"\(session.displayName)\" to:")
        }
        .alert("Kill Session", isPresented: $showKillAlert, presenting: sessionToKill) { session in
            Button("Kill", role: .destructive) {
                killSession(session)
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Are you sure you want to kill tmux session \"\(session.displayName)\"? This will terminate the agent process.")
        }
        .alert("New Group", isPresented: $showGroupAlert) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let session = sessionForGroup {
                    store.assignSession(session, toGroup: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new session group:")
        }
        .alert("Rename Group", isPresented: $showRenameGroupAlert, presenting: groupToRename) { name in
            TextField("Group name", text: $renameGroupText)
            Button("Rename") {
                store.renameGroup(name, to: renameGroupText)
            }
            Button("Cancel", role: .cancel) {}
        } message: { name in
            Text("Rename group \"\(name)\" to:")
        }
    }

    /// A thin strip on the sidebar's trailing edge. Drag it to resize the
    /// sidebar; double-click it to reset the width.
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // The translation is relative to where the drag began,
                        // so the width at that moment is the starting point.
                        let start = resizeStartWidth ?? store.sidebarWidth
                        if resizeStartWidth == nil { resizeStartWidth = start }
                        store.resizeSidebar(to: start + value.translation.width)
                    }
                    .onEnded { _ in
                        resizeStartWidth = nil
                        store.commitSidebarWidth()
                    }
            )
            .onTapGesture(count: 2) {
                store.resetSidebarWidth()
            }
    }

    private var machineFilterBar: some View {
        let machines = store.availableMachines
        if machines.count <= 1 {
            return AnyView(EmptyView())
        }
        return AnyView(
            Picker("Machine", selection: Binding(
                get: { store.machineFilter ?? "All Machines" },
                set: { store.machineFilter = $0 == "All Machines" ? nil : $0 }
            )) {
                ForEach(machines, id: \.self) { m in
                    Text(m).tag(m).font(.caption)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        )
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
            Button(action: { store.showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Settings")
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
                    ForEach(store.sidebarGroups) { group in
                        GroupHeaderRow(store: store, group: group) {
                            groupToRename = group.name
                            renameGroupText = group.name
                            showRenameGroupAlert = true
                        }
                        if !group.isCollapsed {
                            VStack(spacing: 0) {
                                ForEach(group.sessions) { session in
                                    sessionTile(session, group: group.name)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 4)
                        }
                    }
                    ForEach(store.ungroupedSessions) { session in
                        sessionTile(session, group: nil)
                    }
                    trailingDropZone
                }
            }
        }
    }

    private func sessionTile(_ session: ClaudeSession, group: String?) -> some View {
        SidebarSessionTile(
            store: store,
            session: session,
            isActive: session.id == store.activeSessionID,
            group: group,
            onSelect: { onSelectSession(session) }
        )
        .contextMenu { sessionContextMenu(session) }
    }

    /// Trailing gap: dropping here appends to the end of the ungrouped
    /// region (sessions) or the end of the group list (groups).
    private var trailingDropZone: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .dropDestination(
                for: SidebarDragItem.self,
                action: { items, _ in
                    guard let item = items.first else { return false }
                    routeSidebarDrop(store, item: item, targetGroup: nil, anchor: nil, after: true)
                    return true
                },
                isTargeted: { trailingTargeted = $0 }
            )
            .background(trailingTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    @ViewBuilder
    private func sessionContextMenu(_ session: ClaudeSession) -> some View {
        if session.terminalTarget != nil {
            Button("Open Terminal") { onSelectSession(session) }
            Button("Reconnect") { onReconnectSession?(session) }
        }
        Divider()
        if session.tmuxSession != nil {
            Button("Rename Session") {
                sessionToRename = session
                renameText = session.displayName
                showRenameAlert = true
            }
            Button("Kill Session", role: .destructive) {
                sessionToKill = session
                showKillAlert = true
            }
            Divider()
        }
        if !store.groupNames.isEmpty || session.tmuxSession != nil {
            Menu("Assign to Group") {
                ForEach(store.groupNames, id: \.self) { group in
                    Button(group) {
                        store.assignSession(session, toGroup: group)
                    }
                }
                if store.groupName(for: session) != nil {
                    Button("Remove from Group", role: .destructive) {
                        store.assignSession(session, toGroup: nil)
                    }
                }
                Divider()
                Button("New Group...") {
                    sessionForGroup = session
                    newGroupName = ""
                    showGroupAlert = true
                }
            }
        }
        Divider()
        Button("Remove from Sidebar", role: .destructive) {
            store.hideSession(session)
        }
    }

    private func renameSession(_ session: ClaudeSession, to newName: String) {
        guard let tmuxSession = session.tmuxSession, !newName.isEmpty else { return }
        Task {
            let success = await TmuxHelpers.renameSession(currentName: tmuxSession, newName: newName)
            if success {
                await MainActor.run {
                    store.hideSession(session)
                }
            }
        }
    }

    private func killSession(_ session: ClaudeSession) {
        guard let name = session.tmuxSession else { return }
        Task {
            let success = await TmuxHelpers.killSession(named: name)
            if success {
                await MainActor.run {
                    store.hideSession(session)
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
    /// When set, renders a drag handle that initiates sidebar reordering.
    var dragItem: SidebarDragItem? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let dragItem {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .onTapGesture {}
                    .draggable(dragItem)
            }
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.6), radius: statusGlow ? 3 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if session.isRemote, let machine = session.machine {
                        let mc = MachineColors.color(for: machine)
                        Text(machine)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(mc.background)
                            .foregroundStyle(mc.foreground)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(session.agent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let group = session.group, !group.isEmpty {
                    // The group the server says the session belongs to
                    // (ADR 0017), shown on the tile.
                    Text(group)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                }
                if let task = session.task, !task.isEmpty {
                    Text(task)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        case .idle, .ended, .unknown: return idleFadingColor
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
