import SwiftUI
import AppKit

/// Speedrun UI — cycles through waiting agents with embedded terminals.
/// Auto-advances when the current agent starts working (detected via capture-pane polling).
struct SpeedrunView: View {
    var store: NotificationStore
    var onExit: () -> Void

    @State private var advanceTimer: Timer? = nil
    @State private var safetyTimer: Timer? = nil
    @State private var lastSeenStatus: AgentNotification.Status? = nil
    @State private var pollTimer: Timer? = nil
    @State private var lastPaneContent: String = ""
    @State private var promptAbsentCount: Int = 0
    @State private var switchCountdown: Int = 3
    @State private var switchTimer: Timer? = nil
    @State private var keyMonitor: Any? = nil
    @State private var tabMonitor: Any? = nil
    @State private var enterMonitor: Any? = nil
    @State private var lastEnterPress: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
        }
        .onDisappear { stopAllTimers() }
        .onChange(of: store.waitingCount) { _, newCount in
            // When touring and an agent starts needing input, switch back to input-needed mode.
            // But only interrupt if the user isn't actively mid-interaction (i.e., during switching
            // overlay or when viewing an idle/working agent in touring mode).
            guard store.speedrunTouring, newCount > 0 else { return }
            NSSound(named: "Tink")?.play()
            store.stopTouring()
            // If we're on the switching overlay or allWorking, jump to the waiting agent
            if case .viewing = store.speedrunState {
                // Currently viewing an agent — let user finish (tab/input will advance).
                // But if this agent isn't the one that started waiting, the next advance
                // will pick up the waiting agent since we switched back to input-needed mode.
                return
            }
            // Otherwise jump to the first waiting agent
            if let first = store.waitingQueue.first {
                store.viewAgent(first.id)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button(action: exitSpeedrun) {
                Label("Exit", systemImage: "xmark")
            }
            .buttonStyle(.bordered)

            Spacer()

            currentSessionLabel

            Spacer()

            Button(action: skipToNext) {
                Label("Skip", systemImage: "forward.fill")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .contentShape(Rectangle())
    }

    /// Session name + queue indicator combined in the center of the header.
    private var currentSessionLabel: some View {
        HStack(spacing: 8) {
            if let name = currentNotificationName {
                Text(name)
                    .font(.callout.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("·")
                    .foregroundStyle(.tertiary)
            }

            queueIndicator
        }
    }

    private var currentNotificationName: String? {
        if let notification = store.currentSpeedrunNotification {
            return notification.sessionName
        }
        // During advancing, try to find the name from the "from" id
        if case .advancing = store.speedrunState,
           let fromID = lastViewedNotificationID,
           let notification = store.notifications.first(where: { $0.id == fromID }) {
            return notification.sessionName
        }
        return nil
    }

    /// Track the last viewed notification ID so we can show its name during transitions.
    @State private var lastViewedNotificationID: UUID? = nil

    private var queueIndicator: some View {
        Group {
            if store.speedrunTouring {
                let queue = store.allAgentsQueue
                if let current = store.currentSpeedrunNotification,
                   let idx = queue.firstIndex(where: { $0.id == current.id }) {
                    Text("\(idx + 1)/\(queue.count) touring")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                } else {
                    Text("\(queue.count) agents")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
            } else {
                let queue = store.waitingQueue
                if let current = store.currentSpeedrunNotification,
                   let idx = queue.firstIndex(where: { $0.id == current.id }) {
                    Text("\(idx + 1)/\(queue.count) waiting")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                } else if queue.isEmpty {
                    Label("All agents working", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("\(queue.count) waiting")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch store.speedrunState {
        case .idle:
            idleView
        case .viewing(let id):
            if let notification = store.notifications.first(where: { $0.id == id }),
               let target = notification.tmuxPane ?? notification.tmuxSession {
                terminalArea(for: notification, target: target)
            } else {
                missingSessionView
            }
        case .advancing:
            advancingView
        case .switching(_, let toID):
            if let notification = store.notifications.first(where: { $0.id == toID }) {
                switchingOverlay(to: notification)
            } else {
                advancingView
            }
        case .allWorking:
            allWorkingView
        }
    }

    private func terminalArea(for notification: AgentNotification, target: String) -> some View {
        TerminalContainerView(target: target, machineHost: nil, zoomLevel: store.zoomLevel)
            .id(target)
            .onAppear {
                setupForAgent(notification)
            }
            .onDisappear {
                stopPanePolling()
            }
            .onChange(of: store.speedrunState) { _, newState in
                // Re-setup polling when state changes to viewing this agent
                // (e.g. after Skip, where .onAppear may not fire)
                if case .viewing(let id) = newState, id == notification.id {
                    setupForAgent(notification)
                }
            }
            .onChange(of: notificationStatus(for: notification.id)) { _, newStatus in
                guard let newStatus else { return }
                if lastSeenStatus == .waitingForInput && newStatus != .waitingForInput {
                    beginAdvance()
                }
                lastSeenStatus = newStatus
            }
    }

    private func setupForAgent(_ notification: AgentNotification) {
        lastSeenStatus = notification.status
        lastViewedNotificationID = notification.id
        lastPaneContent = ""
        promptAbsentCount = 0
        lastEnterPress = .distantPast
        syncSidebarHighlight(for: notification)
        startPanePolling(paneID: notification.tmuxPane ?? notification.tmuxSession)
        installTabSkipMonitor(for: notification.id)
        installEnterMonitor()
    }

    /// Track Enter key presses so we only auto-advance after confirmed user submission.
    private func installEnterMonitor() {
        removeEnterMonitor()
        enterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Enter key (keyCode 36), no command modifier (Cmd+Enter is different)
            if event.keyCode == 36, !event.modifierFlags.contains(.command) {
                lastEnterPress = Date()
            }
            return event
        }
    }

    private func removeEnterMonitor() {
        if let monitor = enterMonitor {
            NSEvent.removeMonitor(monitor)
            enterMonitor = nil
        }
    }

    /// While viewing an agent, Tab triggers the switching overlay to skip forward.
    private func installTabSkipMonitor(for currentID: UUID) {
        removeTabSkipMonitor()
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard case .viewing = store.speedrunState else { return event }
            // Tab key (keyCode 48), no modifiers (shift+tab is used by Claude for cycling)
            guard event.keyCode == 48,
                  !event.modifierFlags.contains(.shift) else { return event }

            // Find the next agent in the active queue
            let queue = store.activeSpeedrunQueue
            let nextNotification: AgentNotification?
            if let idx = queue.firstIndex(where: { $0.id == currentID }) {
                let nextIdx = queue.index(after: idx)
                if nextIdx < queue.endIndex {
                    nextNotification = queue[nextIdx]
                } else if let first = queue.first, first.id != currentID {
                    nextNotification = first
                } else {
                    nextNotification = nil
                }
            } else {
                nextNotification = queue.first
            }

            if let next = nextNotification {
                stopPanePolling()
                removeTabSkipMonitor()
                store.beginSwitching(from: currentID, to: next.id)
            }
            // Consume the tab so it doesn't go to the terminal
            return nil
        }
    }

    private func removeTabSkipMonitor() {
        if let monitor = tabMonitor {
            NSEvent.removeMonitor(monitor)
            tabMonitor = nil
        }
    }

    private func notificationStatus(for id: UUID) -> AgentNotification.Status? {
        store.notifications.first(where: { $0.id == id })?.status
    }

    // MARK: - Sidebar Sync

    /// Update the sidebar highlight to match the current speedrun agent.
    private func syncSidebarHighlight(for notification: AgentNotification) {
        let target = notification.tmuxPane ?? notification.tmuxSession
        if let session = store.sessions.first(where: { $0.terminalTarget == target }) {
            store.selectSession(session.id)
        }
    }

    // MARK: - Capture-Pane Polling

    private func startPanePolling(paneID: String?) {
        stopPanePolling()
        promptAbsentCount = 0
        guard let paneID else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task {
                await checkIfAgentStartedWorking(paneID: paneID)
            }
        }
    }

    private func stopPanePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Detect when an agent transitions from awaiting-input to working.
    /// Uses the same signal detection as SessionMonitor.checkPaneState:
    /// - Immediate advance on "esc to interrupt" or progress indicators (strong working signals)
    /// - Prompt absence requires 3 consecutive polls (guards against autocomplete/slash popups)
    /// - Content change + prompt gone = immediate advance (user submitted input)
    private func checkIfAgentStartedWorking(paneID: String) async {
        guard let output = await TmuxHelpers.run(arguments: [
            "capture-pane", "-t", paneID, "-p", "-J"
        ]) else { return }

        let lines = output.components(separatedBy: "\n")
        let tail = lines.suffix(25)

        // --- Strong working signals: advance immediately ---
        for line in tail {
            let lower = line.lowercased()
            if lower.contains("esc to interrupt") {
                await MainActor.run { beginAdvance() }
                return
            }
            if lower.contains("...") && lower.contains("token") {
                await MainActor.run { beginAdvance() }
                return
            }
        }

        // --- Check for prompt ---
        var hasCommandPrompt = false
        for line in tail {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("❯") else { continue }
            let afterCursor = String(trimmed.dropFirst("❯".count))
                .trimmingCharacters(in: .whitespaces)
            // Selection cursor (❯ 1. Yes) is NOT a command prompt
            if afterCursor.count >= 2,
               afterCursor.first?.isNumber == true,
               afterCursor[afterCursor.index(after: afterCursor.startIndex)] == "." {
                continue
            }
            hasCommandPrompt = true
        }

        await MainActor.run {
            let contentChanged = !lastPaneContent.isEmpty && output != lastPaneContent

            if hasCommandPrompt {
                // Prompt is visible. If content changed significantly (user may have
                // submitted and Claude already finished), check if the output above
                // the prompt changed — that means work was done.
                if contentChanged && promptAbsentCount > 0 {
                    // Prompt disappeared briefly then came back = agent processed quickly
                    beginAdvance()
                }
                promptAbsentCount = 0
            } else if !lastPaneContent.isEmpty {
                promptAbsentCount += 1
                // If content changed AND prompt is gone, advance after just 1 poll
                // (user clearly submitted input). Otherwise wait for 3 polls to guard
                // against autocomplete/slash command popups.
                if contentChanged && promptAbsentCount >= 1 {
                    beginAdvance()
                } else if promptAbsentCount >= 3 {
                    beginAdvance()
                }
            }
            lastPaneContent = output
        }
    }

    // MARK: - State Views

    private var idleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Starting speedrun...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.startSpeedrun()
        }
    }

    private var advancingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Advancing to next agent...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            safetyTimer?.invalidate()
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
                Task { @MainActor in
                    guard store.speedrunState == .advancing else { return }
                    resolveNextAfterAdvance()
                }
            }
        }
    }

    /// Context-shifting overlay — shows for 3 seconds with keyboard controls.
    private func switchingOverlay(to notification: AgentNotification) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Switching to")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(notification.sessionName)
                .font(.title2.bold())
                .foregroundStyle(.primary)

            Text("\(switchCountdown)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
                .contentTransition(.numericText())
                .animation(.default, value: switchCountdown)

            VStack(spacing: 6) {
                keyHint(key: "Enter", label: "Proceed now")
                keyHint(key: "Esc", label: "Go back")
                keyHint(key: "Tab", label: "Skip to next")
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .onAppear {
            syncSidebarHighlight(for: notification)
            startSwitchCountdown(to: notification.id)
            installSwitchKeyMonitor(to: notification.id)
        }
        .onDisappear {
            stopSwitchCountdown()
            removeSwitchKeyMonitor()
        }
    }

    private func keyHint(key: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.caption.monospaced().bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var allWorkingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting tour of all agents...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Transition to touring mode immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard store.speedrunMode, store.speedrunState == .allWorking else { return }
                store.startTouring()
            }
        }
    }

    private var missingSessionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("No tmux session")
                .font(.headline)
            Text("This agent doesn't have a tmux pane. Skipping...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard store.speedrunMode else { return }
                store.viewNext()
            }
        }
    }

    // MARK: - Switch Countdown

    private func startSwitchCountdown(to targetID: UUID) {
        switchCountdown = 3
        switchTimer?.invalidate()
        switchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard case .switching = store.speedrunState else {
                    stopSwitchCountdown()
                    return
                }
                switchCountdown -= 1
                if switchCountdown <= 0 {
                    stopSwitchCountdown()
                    removeSwitchKeyMonitor()
                    store.viewAgent(targetID)
                }
            }
        }
    }

    private func stopSwitchCountdown() {
        switchTimer?.invalidate()
        switchTimer = nil
    }

    private func installSwitchKeyMonitor(to targetID: UUID) {
        removeSwitchKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard case .switching(let fromID, let toID) = store.speedrunState else { return event }

            switch event.keyCode {
            case 36: // Enter — proceed immediately
                stopSwitchCountdown()
                removeSwitchKeyMonitor()
                store.viewAgent(toID)
                return nil
            case 53: // Esc — go back to previous
                stopSwitchCountdown()
                removeSwitchKeyMonitor()
                store.viewAgent(fromID)
                return nil
            case 48: // Tab — skip to next in queue
                // Find the agent AFTER toID and re-show the switching overlay
                let queue = store.activeSpeedrunQueue
                let nextNext: AgentNotification?
                if let idx = queue.firstIndex(where: { $0.id == toID }) {
                    let nn = queue.index(after: idx)
                    if nn < queue.endIndex {
                        nextNext = queue[nn]
                    } else if let first = queue.first, first.id != toID {
                        nextNext = first
                    } else {
                        nextNext = nil
                    }
                } else {
                    nextNext = queue.first
                }

                if let next = nextNext {
                    // Update the switching target and restart countdown + key monitor
                    stopSwitchCountdown()
                    removeSwitchKeyMonitor()
                    store.beginSwitching(from: fromID, to: next.id)
                    if let notif = store.notifications.first(where: { $0.id == next.id }) {
                        syncSidebarHighlight(for: notif)
                    }
                    startSwitchCountdown(to: next.id)
                    installSwitchKeyMonitor(to: next.id)
                } else {
                    // No more agents to skip to
                    stopSwitchCountdown()
                    removeSwitchKeyMonitor()
                    store.viewAgent(toID)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeSwitchKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Auto-Advance

    /// Begin advance: after detecting agent started working (or tab-skipped),
    /// find the next agent and transition to the switching overlay.
    /// Only advances if the user pressed Enter recently (within 5 seconds),
    /// confirming they actually submitted input.
    private func beginAdvance() {
        guard case .viewing(let currentID) = store.speedrunState else { return }

        // Only auto-advance if user pressed Enter recently
        let secondsSinceEnter = Date().timeIntervalSince(lastEnterPress)
        if secondsSinceEnter > 5 { return }

        stopPanePolling()
        removeTabSkipMonitor()

        // Use the active queue (waiting agents in input-needed mode, all agents in touring)
        let queue = store.activeSpeedrunQueue
        let nextNotification: AgentNotification?
        if let idx = queue.firstIndex(where: { $0.id == currentID }) {
            let nextIdx = queue.index(after: idx)
            if nextIdx < queue.endIndex {
                nextNotification = queue[nextIdx]
            } else if let first = queue.first, first.id != currentID {
                nextNotification = first
            } else {
                nextNotification = nil
            }
        } else {
            nextNotification = queue.first
        }

        if let next = nextNotification {
            store.beginSwitching(from: currentID, to: next.id)
        } else if !store.speedrunTouring {
            // No more waiting agents — switch to touring with a transition
            store.startTouring(switchingFrom: currentID)
        } else {
            store.advanceSpeedrun()
            advanceTimer?.invalidate()
            advanceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                Task { @MainActor in
                    guard store.speedrunMode else { return }
                    resolveNextAfterAdvance()
                }
            }
        }
    }

    /// After the advancing state, move to the next available agent.
    private func resolveNextAfterAdvance() {
        let fromID = lastViewedNotificationID
        if let next = store.activeSpeedrunQueue.first {
            store.viewAgent(next.id)
        } else if !store.speedrunTouring {
            store.startTouring(switchingFrom: fromID)
        } else {
            store.setAllWorking()
        }
    }

    private func exitSpeedrun() {
        stopAllTimers()
        removeSwitchKeyMonitor()
        removeTabSkipMonitor()
        removeEnterMonitor()
        store.stopSpeedrun()
        onExit()
    }

    private func skipToNext() {
        stopPanePolling()
        removeSwitchKeyMonitor()
        removeTabSkipMonitor()
        store.viewNext()
    }

    private func stopAllTimers() {
        advanceTimer?.invalidate()
        advanceTimer = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
        stopPanePolling()
        stopSwitchCountdown()
    }
}
