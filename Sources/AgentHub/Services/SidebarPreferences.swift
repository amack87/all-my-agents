import Foundation

/// Persists sidebar session visibility preferences to disk.
/// Sessions removed from the sidebar are tracked by tmux session name
/// and excluded from display until explicitly re-added.
enum SidebarPreferences {
    private static let configDir = NSHomeDirectory() + "/.config/allmyagents"
    private static let filePath = configDir + "/sidebar-preferences.json"

    private struct Storage: Codable {
        let hiddenSessionNames: [String]
    }

    // MARK: - Public API

    static func loadHiddenSessionNames() -> Set<String> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath),
              let data = fm.contents(atPath: filePath),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else { return [] }
        return Set(storage.hiddenSessionNames)
    }

    static func save(hiddenSessionNames: Set<String>) {
        let fm = FileManager.default
        // Ensure config directory exists
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }

        let storage = Storage(hiddenSessionNames: Array(hiddenSessionNames).sorted())
        guard let data = try? JSONEncoder().encode(storage) else { return }
        fm.createFile(atPath: filePath, contents: data)
    }
}
