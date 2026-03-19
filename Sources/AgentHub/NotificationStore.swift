import Foundation
import Observation

@Observable
@MainActor
final class NotificationStore {
    private(set) var notifications: [AgentNotification] = []
    private(set) var speedrunMode: Bool = false
    private(set) var speedrunState: SpeedrunState = .idle
    /// When true, speedrun is touring all agents (no agents need input).
    /// When false, speedrun focuses on agents awaiting input.
    private(set) var speedrunTouring: Bool = false

    // Session sidebar state
    private(set) var sessions: [ClaudeSession] = []
    private(set) var activeSessionID: String? = nil
    var sidebarVisible: Bool = true

    /// Tmux session names the user has removed from the sidebar.
    /// Persisted to disk so they stay hidden across app restarts.
    private(set) var hiddenSessionNames: Set<String> = SidebarPreferences.loadHiddenSessionNames()

    /// Whether the "Add Session" sheet is presented.
    var showingAddSession: Bool = false

    /// Tmux session name that was just created/selected via AddSessionSheet,
    /// pending resolution to a real session ID once the monitor discovers it.
    private(set) var pendingSessionName: String? = nil

    // MARK: - Zoom

    private static let zoomSteps: [CGFloat] = [0.75, 0.85, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5]
    private static let zoomDefaultsKey = "allmyagents-zoom-index"

    /// Current zoom level (1.0 = 100%). Affects terminal font size.
    private(set) var zoomLevel: CGFloat = {
        let saved = UserDefaults.standard.integer(forKey: zoomDefaultsKey)
        let idx = (saved >= 0 && saved < zoomSteps.count) ? saved : zoomSteps.firstIndex(of: 1.0) ?? 3
        return zoomSteps[idx]
    }()

    private var zoomIndex: Int {
        Self.zoomSteps.firstIndex(of: zoomLevel) ?? Self.zoomSteps.firstIndex(of: 1.0) ?? 3
    }

    func adjustZoom(by delta: Int) {
        let newIndex = min(max(zoomIndex + delta, 0), Self.zoomSteps.count - 1)
        zoomLevel = Self.zoomSteps[newIndex]
        UserDefaults.standard.set(newIndex, forKey: Self.zoomDefaultsKey)
    }

    func resetZoom() {
        let defaultIndex = Self.zoomSteps.firstIndex(of: 1.0) ?? 3
        zoomLevel = Self.zoomSteps[defaultIndex]
        UserDefaults.standard.set(defaultIndex, forKey: Self.zoomDefaultsKey)
    }

    enum SpeedrunState: Equatable {
        case idle
        case viewing(UUID)
        case advancing
        /// Context-shifting overlay: from previous notification, to next notification
        case switching(from: UUID, to: UUID)
        case allWorking
    }

    static let shared = NotificationStore()
    private init() {}

    // MARK: - Computed

    var waitingCount: Int {
        notifications.filter { $0.status == .waitingForInput }.count
    }

    var waitingQueue: [AgentNotification] {
        notifications.filter { $0.status == .waitingForInput }
    }

    /// All agents that have tmux sessions (for idle-tour mode).
    var allAgentsQueue: [AgentNotification] {
        notifications.filter { $0.tmuxPane != nil || $0.tmuxSession != nil }
    }

    /// The active queue: waiting agents if any need input, otherwise all agents.
    var activeSpeedrunQueue: [AgentNotification] {
        speedrunTouring ? allAgentsQueue : waitingQueue
    }

    // MARK: - Mutations (all return new arrays, never mutate in place)

    func addNotification(_ notification: AgentNotification) {
        var updated = [notification] + notifications
        if updated.count > 50 {
            updated = Array(updated.prefix(50))
        }
        notifications = updated
    }

    /// Find an existing notification that matches the same session by any key:
    /// tmuxPane, sessionID, or sessionName (in priority order).
    private func findExistingIndex(
        tmuxPane: String? = nil,
        sessionID: String? = nil,
        sessionName: String? = nil
    ) -> Int? {
        // Match by tmux pane first (most specific)
        if let pane = tmuxPane,
           let index = notifications.firstIndex(where: { $0.tmuxPane == pane }) {
            return index
        }
        // Match by session ID
        if let sid = sessionID, !sid.isEmpty,
           let index = notifications.firstIndex(where: { $0.sessionID == sid }) {
            return index
        }
        // Match by session name
        if let name = sessionName, !name.isEmpty,
           let index = notifications.firstIndex(where: { $0.sessionName == name }) {
            return index
        }
        return nil
    }

    /// Upsert from webhook — matches on tmuxPane, sessionID, or sessionName.
    func upsertFromWebhook(_ notification: AgentNotification) {
        if let index = findExistingIndex(
            tmuxPane: notification.tmuxPane,
            sessionID: notification.sessionID,
            sessionName: notification.sessionName
        ) {
            let existing = notifications[index]
            let updated = existing.copy(
                status: notification.status,
                message: notification.message,
                sessionID: notification.sessionID,
                tmuxPane: .some(notification.tmuxPane ?? existing.tmuxPane),
                tmuxSession: .some(notification.tmuxSession ?? existing.tmuxSession),
                statusSource: .webhook
            )
            var newList = notifications
            newList[index] = updated
            notifications = newList
        } else {
            addNotification(notification)
        }
    }

    /// Upsert from tmux discovery — matches on tmuxPane, sessionID, or sessionName.
    func upsertFromTmux(
        tmuxPane: String,
        tmuxSession: String?,
        status: AgentNotification.Status,
        sessionName: String,
        sessionID: String? = nil
    ) {
        if let index = findExistingIndex(
            tmuxPane: tmuxPane,
            sessionID: sessionID,
            sessionName: sessionName
        ) {
            let existing = notifications[index]
            if existing.status != status {
                let updated = existing.copy(
                    status: status,
                    message: Self.messageForStatus(status),
                    tmuxPane: tmuxPane,
                    tmuxSession: .some(tmuxSession ?? existing.tmuxSession),
                    statusSource: .tmux
                )
                var newList = notifications
                newList[index] = updated
                notifications = newList
            }
        } else {
            let notification = AgentNotification(
                agent: "claude-code",
                status: status,
                sessionName: sessionName,
                message: Self.messageForStatus(status),
                sessionID: sessionID,
                tmuxPane: tmuxPane,
                tmuxSession: tmuxSession,
                statusSource: .tmux
            )
            addNotification(notification)
        }
    }

    private static func messageForStatus(_ status: AgentNotification.Status) -> String {
        switch status {
        case .waitingForInput: return "Agent needs your attention"
        case .completed: return "Agent completed work"
        case .error: return "Agent encountered an error"
        }
    }

    /// Remove notification for a tmux pane that no longer exists.
    func removeTmuxPane(_ pane: String) {
        notifications = notifications.filter { $0.tmuxPane != pane }
    }

    func remove(id: UUID) {
        notifications = notifications.filter { $0.id != id }
    }

    func clearAll() {
        notifications = []
    }

    // MARK: - Sessions

    /// Visible sessions (excluding user-hidden ones), sorted by priority.
    var sortedSessions: [ClaudeSession] {
        let visible = sessions.filter { session in
            let name = session.tmuxSession ?? session.displayName
            return !hiddenSessionNames.contains(name)
        }
        let active = visible.filter { $0.id == activeSessionID }
        let needsInput = visible.filter { $0.id != activeSessionID && $0.status == .needsInput }
        let working = visible.filter { $0.id != activeSessionID && $0.status == .working }
        let rest = visible.filter { $0.id != activeSessionID && ($0.status == .idle || $0.status == .unknown) }
        return active + needsInput + working + rest
    }

    /// Sessions the user has hidden from the sidebar (available but not tracked).
    var availableSessions: [ClaudeSession] {
        sessions
            .filter { session in
                let name = session.tmuxSession ?? session.displayName
                return hiddenSessionNames.contains(name)
            }
            .sorted { ($0.tmuxSession ?? $0.displayName) < ($1.tmuxSession ?? $1.displayName) }
    }

    func updateSessions(_ newSessions: [ClaudeSession]) {
        sessions = newSessions

        // Resolve pending session name to a real session ID
        if let pending = pendingSessionName,
           let real = newSessions.first(where: { $0.tmuxSession == pending }) {
            activeSessionID = real.id
            pendingSessionName = nil
        }

        // Clear activeSessionID if that session disappeared
        if let active = activeSessionID, !newSessions.contains(where: { $0.id == active }) {
            activeSessionID = nil
        }
    }

    /// Mark a tmux session name as pending selection — the next monitor
    /// refresh that discovers it will automatically select it.
    func setPendingSession(named name: String) {
        pendingSessionName = name
    }

    /// Hide a session from the sidebar by its tmux session name,
    /// falling back to display name for non-tmux sessions.
    func hideSession(_ session: ClaudeSession) {
        let name = session.tmuxSession ?? session.displayName
        let updated = hiddenSessionNames.union([name])
        hiddenSessionNames = updated
        SidebarPreferences.save(hiddenSessionNames: updated)
        // Deselect if this was the active session
        if activeSessionID == session.id {
            activeSessionID = nil
        }
    }

    /// Unhide a session name so it appears in the sidebar again.
    func unhideSession(named name: String) {
        let updated = hiddenSessionNames.subtracting([name])
        hiddenSessionNames = updated
        SidebarPreferences.save(hiddenSessionNames: updated)
    }

    func selectSession(_ id: String) {
        activeSessionID = id
    }

    func toggleSidebar() {
        sidebarVisible = !sidebarVisible
    }

    // MARK: - Speedrun

    func startSpeedrun() {
        speedrunMode = true
        if let first = waitingQueue.first {
            speedrunTouring = false
            speedrunState = .viewing(first.id)
        } else if let first = allAgentsQueue.first {
            speedrunTouring = true
            speedrunState = .viewing(first.id)
        } else {
            speedrunState = .allWorking
        }
    }

    func stopSpeedrun() {
        speedrunMode = false
        speedrunState = .idle
        speedrunTouring = false
    }

    func advanceSpeedrun() {
        speedrunState = .advancing
    }

    /// Transition to the switching overlay showing the next agent.
    func beginSwitching(from currentID: UUID, to nextID: UUID) {
        speedrunState = .switching(from: currentID, to: nextID)
    }

    func viewAgent(_ id: UUID) {
        speedrunState = .viewing(id)
    }

    func setAllWorking() {
        speedrunState = .allWorking
    }

    /// Switch to touring mode (all agents) when no agents need input.
    /// If `switchingFrom` is provided, shows the switching overlay instead of jumping directly.
    func startTouring(switchingFrom fromID: UUID? = nil) {
        speedrunTouring = true
        if let first = allAgentsQueue.first {
            if let fromID {
                speedrunState = .switching(from: fromID, to: first.id)
            } else {
                speedrunState = .viewing(first.id)
            }
        } else {
            speedrunState = .allWorking
        }
    }

    /// Switch back to input-needed mode when an agent starts waiting.
    func stopTouring() {
        speedrunTouring = false
    }

    func viewNext() {
        guard let currentID = currentSpeedrunID ?? switchingFromID else {
            if let next = activeSpeedrunQueue.first {
                speedrunState = .viewing(next.id)
            } else if speedrunTouring {
                speedrunState = .allWorking
            } else {
                // No waiting agents — switch to touring
                startTouring()
            }
            return
        }
        let queue = activeSpeedrunQueue
        if let currentIndex = queue.firstIndex(where: { $0.id == currentID }) {
            let nextIndex = queue.index(after: currentIndex)
            if nextIndex < queue.endIndex {
                speedrunState = .viewing(queue[nextIndex].id)
            } else if let first = queue.first, first.id != currentID {
                // Wrap around
                speedrunState = .viewing(first.id)
            } else if speedrunTouring {
                // Only one agent in tour, stay on it
                speedrunState = .viewing(currentID)
            } else {
                // Exhausted waiting queue — switch to touring with transition
                startTouring(switchingFrom: currentID)
            }
        } else if let next = queue.first {
            speedrunState = .viewing(next.id)
        } else if !speedrunTouring {
            startTouring(switchingFrom: currentID)
        } else {
            speedrunState = .allWorking
        }
    }

    func viewPrevious() {
        guard let currentID = currentSpeedrunID ?? switchingToID else { return }
        let queue = activeSpeedrunQueue
        guard let currentIndex = queue.firstIndex(where: { $0.id == currentID }) else {
            if let last = queue.last {
                speedrunState = .viewing(last.id)
            }
            return
        }
        if currentIndex > queue.startIndex {
            speedrunState = .viewing(queue[queue.index(before: currentIndex)].id)
        } else if let last = queue.last, last.id != currentID {
            speedrunState = .viewing(last.id)
        }
    }

    var currentSpeedrunID: UUID? {
        if case .viewing(let id) = speedrunState { return id }
        return nil
    }

    /// The "from" ID when in switching state.
    var switchingFromID: UUID? {
        if case .switching(let from, _) = speedrunState { return from }
        return nil
    }

    /// The "to" ID when in switching state.
    var switchingToID: UUID? {
        if case .switching(_, let to) = speedrunState { return to }
        return nil
    }

    var currentSpeedrunNotification: AgentNotification? {
        let id = currentSpeedrunID ?? switchingToID
        guard let id else { return nil }
        return notifications.first { $0.id == id }
    }
}
