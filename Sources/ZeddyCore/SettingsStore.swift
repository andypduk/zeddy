import Foundation

public enum SettingsStore {
    public static func load() -> ZeddySettings {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.settingsFile)),
              let settings = try? JSONDecoder().decode(ZeddySettings.self, from: data) else {
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
