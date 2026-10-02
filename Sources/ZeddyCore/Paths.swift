import Foundation

/// File-system locations for everything Zeddy persists.
///
/// The requirement is that all data live in the user's home directory. We keep
/// a single `~/.zeddy` root and place the store, socket, settings, logs, and
/// pid file under it, so the whole app is easy to inspect and easy to wipe.
public enum Paths {
    /// `~/.zeddy` — the single source of truth.
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zeddy", isDirectory: true)
    }

    /// `~/.zeddy/zeddy.db` — the SQLite database (+ its WAL/SHM side files).
    public static var dbFile: URL { root.appendingPathComponent("zeddy.db") }

    /// `~/.zeddy/zeddy.sock` — the daemon's Unix-domain socket (the IPC channel
    /// the CLI and GUI talk over).
    public static var daemonSocket: URL { root.appendingPathComponent("zeddy.sock") }

    /// `~/.zeddy/daemon.log` — daemon stdout/stderr.
    public static var daemonLog: URL { root.appendingPathComponent("logs").appendingPathComponent("daemon.log") }

    /// `~/.zeddy/daemon.pid` — the daemon's pid (used to stop it).
    public static var pidFile: URL { root.appendingPathComponent("daemon.pid") }

    /// `~/.zeddy/settings.json` — the persisted settings.
    public static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    /// Create `~/.zeddy` and `~/.zeddy/logs` if they do not already exist.
    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: nil
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("logs", isDirectory: true),
            withIntermediateDirectories: true, attributes: nil
        )
    }

    /// Best-effort removal of the whole `~/.zeddy` tree (used by `zeddy reset`).
    public static func removeRoot() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    public static var daemonSocketPath: String { daemonSocket.path }
    public static var dbFileString: String { dbFile.path }
    public static var settingsFilePath: String { settingsFile.path }
    public static var daemonLogPath: String { daemonLog.path }
}

/// The four memory kinds. Deliberately small: each maps to a section in the
/// rendered context, which keeps the output predictable and compact.
public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case note
    case convention
    case decision
    case preference
}
