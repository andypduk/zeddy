import Foundation

/// All mutable application data is contained in this directory.
/// Set `ZEDDY_HOME` to override the default `~/.zeddy` location.
public enum Paths {
    public static var base: URL {
        if let override = ProcessInfo.processInfo.environment["ZEDDY_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zeddy", isDirectory: true)
    }

    public static var dataDir: URL { base.appendingPathComponent("data", isDirectory: true) }
    public static var dbFile: String { dataDir.appendingPathComponent("memories.db").path }
    public static var settingsFile: String { base.appendingPathComponent("settings.json").path }
    public static var logFile: String { base.appendingPathComponent("zeddy.log").path }
    public static var daemonSocketPath: String { base.appendingPathComponent("zeddy.sock").path }
    public static var pidFile: String { base.appendingPathComponent("zeddy-daemon.pid").path }

    public static func ensureLayout() throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }
}
