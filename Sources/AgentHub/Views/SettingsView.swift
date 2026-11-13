import SwiftUI

struct SettingsView: View {
    var store: NotificationStore

    @State private var backups = BackupService.Settings.defaults
    @State private var backupStatus: String? = nil
    @State private var backupRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.bold())

            meshServerSection

            Divider()

            textSizeSection

            Divider()

            hibernationSection

            Spacer(minLength: 8)

            HStack {
                if let cli = HibernatorService.cliPath {
                    Text("Hibernator: \(cli)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") {
                    store.showSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 470)
        .onAppear {
            backups = BackupService.shared.settings
        }
    }

    // MARK: - Sections

    private var meshServerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Mesh Server")

            Picker("Mesh Server", selection: Binding(
                get: { store.meshServerURL },
                set: { store.meshServerURL = $0 }
            )) {
                ForEach(store.meshServerOptions, id: \.url) { option in
                    Text(option.label).tag(option.url)
                }
            }
            .pickerStyle(.menu)

            Text("The All My Agents web server used for multi-machine session discovery. Known machines are detected from mesh responses; other hosts can be configured with a custom URL via the app's menu.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textSizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Text Size")

            HStack(spacing: 12) {
                Button(action: { store.adjustZoom(by: -1) }) {
                    Image(systemName: "minus")
                }
                .help("Zoom out")

                Text("\(Int((store.zoomLevel * 100).rounded()))%")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 44)

                Button(action: { store.adjustZoom(by: 1) }) {
                    Image(systemName: "plus")
                }
                .help("Zoom in")

                Spacer()

                Button("Reset") { store.resetZoom() }
                    .controlSize(.small)
            }

            Text("Adjusts the terminal font size. Also available from the app's View menu (Zoom In / Out / Actual Size).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var hibernationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Backups & Hibernation")

            if !HibernatorService.isAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Hibernator CLI not found. Set the HIBERNATOR_CLI environment variable to its path.")
                        .font(.caption)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Periodic session backups", isOn: $backups.enabled)
                    .onChange(of: backups.enabled) { _, newValue in
                        BackupService.shared.update { $0.enabled = newValue }
                    }

                HStack {
                    Text("Backup interval (minutes)")
                    Spacer()
                    Stepper(value: $backups.intervalMinutes, in: 1...1440) {
                        Text("\(backups.intervalMinutes)")
                            .font(.body.monospacedDigit())
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .onChange(of: backups.intervalMinutes) { _, newValue in
                        BackupService.shared.update { $0.intervalMinutes = newValue }
                    }
                }

                Toggle("Hibernate idle sessions on quit", isOn: $backups.hibernateOnShutdown)
                    .onChange(of: backups.hibernateOnShutdown) { _, newValue in
                        BackupService.shared.update { $0.hibernateOnShutdown = newValue }
                    }

                Text("This app drives the hibernator CLI directly: a backup captures each session's context without ending it, and quitting hibernates the idle sessions. Active sessions are left untouched.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Backup Now") { runBackupNow() }
                        .disabled(backupRunning || !HibernatorService.isAvailable)

                    if backupRunning {
                        ProgressView().controlSize(.small)
                    }
                    if let status = backupStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func runBackupNow() {
        backupRunning = true
        backupStatus = nil
        Task { @MainActor in
            backupStatus = await BackupService.shared.backupNow()
            backupRunning = false
        }
    }
}
