import Foundation

/// Loads and saves `ZeddySettings` from `~/.zeddy/settings.json`.
public enum SettingsStore {
    public static func load() -> ZeddySettings {
        let path = Paths.settingsFile
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let settings = try? JSONDecoder().decode(ZeddySettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public static func save(_ settings: ZeddySettings) throws {
        try Paths.ensureLayout()
        let data = try JSONEncoder().encode(settings)
        try data.write(to: URL(fileURLWithPath: Paths.settingsFile), options: .atomic)
    }
}
