import SwiftUI

struct SettingsView: View {
    var store: NotificationStore

    @State private var settings: MeshAPIClient.ServerSettings = .defaults
    @State private var settingsLoaded = false
    @State private var saveFailed = false
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

            if saveFailed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Could not reach the server to save settings.")
                        .font(.caption)
                    Spacer()
                }
            }

            Spacer(minLength: 8)

            HStack {
                if settingsLoaded && !backupRunning {
                    Text("Settings apply to the server at \(store.meshServerURL)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
            loadSettings()
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
            sectionHeader("Hibernation")

            if !settingsLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading server settings…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Periodic session backups", isOn: $settings.backup.enabled)
                        .onChange(of: settings.backup.enabled) { saveSettings() }

                    HStack {
                        Text("Backup interval (minutes)")
                        Spacer()
                        Stepper(value: $settings.backup.intervalMinutes, in: 1...1440) {
                            Text("\(settings.backup.intervalMinutes)")
                                .font(.body.monospacedDigit())
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .onChange(of: settings.backup.intervalMinutes) { saveSettings() }
                    }

                    Toggle("Hibernate idle sessions on shutdown", isOn: $settings.shutdownHibernate.enabled)
                        .onChange(of: settings.shutdownHibernate.enabled) { saveSettings() }

                    Text("When the server receives a shutdown signal, idle agent sessions are saved (context captured, then the session is ended). Active sessions are left untouched.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("Backup Now") { runBackupNow() }
                            .disabled(backupRunning)

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
                .disabled(!settingsLoaded || saveFailed)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func loadSettings() {
        settingsLoaded = false
        saveFailed = false
        backupStatus = nil
        Task {
            let loaded = await MeshAPIClient.fetchSettings(serverURL: store.meshServerURL)
            if let loaded {
                settings = loaded
                settingsLoaded = true
            } else {
                settingsLoaded = false
            }
        }
    }

    private func saveSettings() {
        saveFailed = false
        Task {
            let ok = await MeshAPIClient.saveSettings(settings, serverURL: store.meshServerURL)
            saveFailed = !ok
            if ok {
                // Refresh to pick up any server-side normalization.
                let refreshed = await MeshAPIClient.fetchSettings(serverURL: store.meshServerURL)
                if let refreshed { settings = refreshed }
            }
        }
    }

    private func runBackupNow() {
        backupRunning = true
        backupStatus = nil
        Task {
            backupStatus = await MeshAPIClient.runBackupNow(serverURL: store.meshServerURL)
            backupRunning = false
        }
    }
}
