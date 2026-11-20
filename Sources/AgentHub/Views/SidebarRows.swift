import SwiftUI
import UniformTypeIdentifiers

/// Payload for sidebar drag & drop: a session key or a group name.
/// `kind` is "session" or "group"; `id` is the session key (`host::name`)
/// or the group name.
struct SidebarDragItem: Transferable, Codable, Equatable {
    let kind: String
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .json) { item in
            try JSONEncoder().encode(item)
        } importing: { data in
            try JSONDecoder().decode(SidebarDragItem.self, from: data)
        }
    }
}

/// Routes a dropped item against the row the user released on.
/// - `targetGroup`: group the target row belongs to (nil = ungrouped region)
/// - `anchor`: the session tile under the cursor (nil = header/trailing zone)
/// - `after`: bottom half of the target row (or below it) = insert after
@MainActor func routeSidebarDrop(
    _ store: NotificationStore,
    item: SidebarDragItem,
    targetGroup: String?,
    anchor: ClaudeSession?,
    after: Bool
) {
    if item.kind == "group" {
        if let targetGroup,
           let idx = store.sidebarGroups.firstIndex(where: { $0.name == targetGroup }) {
            store.moveGroup(item.id, to: idx + (after ? 1 : 0))
        } else {
            // Ungrouped tile or trailing zone: append to the end.
            store.moveGroup(item.id, to: store.sidebarGroups.count)
        }
    } else if let anchor {
        store.moveSession(item.id, toGroup: targetGroup, relativeTo: anchor.sidebarKey, after: after)
    } else {
        // Header or trailing zone: append.
        store.moveSession(item.id, toGroup: targetGroup, relativeTo: nil, after: false)
    }
}

/// Collapsible group header: drag handle, chevron, name, live count.
struct GroupHeaderRow: View {
    let store: NotificationStore
    let group: ResolvedSidebarGroup
    var onRenameRequest: () -> Void = {}

    @State private var rowHeight: CGFloat = 30
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .onTapGesture {}
                .draggable(SidebarDragItem(kind: "group", id: group.name))
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(group.isCollapsed ? -90 : 0))
            Text(group.name)
                .font(.caption2.bold())
                .lineLimit(1)
            if group.isServerDeclared {
                // The group exists because the server declared its members
                // (ADR 0017), not because James arranged it — so he knows he
                // does not own this tile-home until he acts on the group.
                Text("SERVER")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
            Spacer()
            Text("\(group.sessions.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { store.toggleGroupCollapsed(group.name) }
        .contextMenu {
            Button("Rename group") { onRenameRequest() }
            Button("Ungroup all") { store.ungroupAll(group.name) }
            Divider()
            Button("Delete group", role: .destructive) { store.deleteGroup(group.name) }
        }
        .dropDestination(
            for: SidebarDragItem.self,
            action: { items, location in
                guard let item = items.first else { return false }
                routeSidebarDrop(
                    store,
                    item: item,
                    targetGroup: group.name,
                    anchor: nil,
                    after: location.y >= rowHeight / 2
                )
                return true
            },
            isTargeted: { isTargeted = $0 }
        )
        .background(heightCapture($rowHeight))
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

/// A session tile: status row + handle-only drag source + drop target.
/// Taps still select/open the session; drags start from the handle only.
struct SidebarSessionTile: View {
    let store: NotificationStore
    let session: ClaudeSession
    let isActive: Bool
    let group: String?
    var onSelect: () -> Void

    @State private var rowHeight: CGFloat = 44
    @State private var isTargeted = false

    var body: some View {
        SessionRowView(
            session: session,
            isActive: isActive,
            dragItem: SidebarDragItem(kind: "session", id: session.sidebarKey)
        )
        .onTapGesture { onSelect() }
        .dropDestination(
            for: SidebarDragItem.self,
            action: { items, location in
                guard let item = items.first else { return false }
                routeSidebarDrop(
                    store,
                    item: item,
                    targetGroup: group,
                    anchor: session,
                    after: location.y >= rowHeight / 2
                )
                return true
            },
            isTargeted: { isTargeted = $0 }
        )
        .background(heightCapture($rowHeight))
        .background(isTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}

/// Keeps `height` in sync with the row's laid-out size (macOS 14-compatible;
/// used to turn drop locations into before/after decisions).
private func heightCapture(_ height: Binding<CGFloat>) -> some View {
    GeometryReader { geo in
        Color.clear
            .onAppear { height.wrappedValue = geo.size.height }
            .onChange(of: geo.size.height) { _, newHeight in
                height.wrappedValue = newHeight
            }
    }
}
