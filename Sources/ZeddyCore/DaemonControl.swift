import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Process control for the `zeddy-daemon` binary, shared by the CLI and the GUI.
///
/// The daemon is the long-lived integration surface (it owns the store and the
/// socket). The CLI and the GUI never launch it inline; they *control* it here:
///   - `start()`  launches it detached into its own session (it survives the
///                caller exiting or the terminal closing), stderr to the log.
///   - `stop()`   sends it SIGTERM via `pkill -x`.
///   - `isRunning()` checks the socket file.
public enum DaemonControl {
    public enum DaemonControlError: Error, CustomStringConvertible {
        case noBinary
        case spawnFailed(Int32)

        public var description: String {
            switch self {
            case .noBinary:
                return "zeddy-daemon binary not found (set ZEDDY_DAEMON to its path)"
            case .spawnFailed(let c):
                return "failed to spawn daemon (\(c))"
            }
        }
    }

    /// Locate the `zeddy-daemon` executable. Resolution order:
    ///  1. `ZEDDY_DAEMON` environment variable (explicit override).
    ///  2. A sibling of the running binary (SPM builds both into the same
    ///     `.build/<config>` directory, so this covers `swift run`).
    ///  3. `~/.zeddy/bin/zeddy-daemon` (a stable, documented install location).
    public static func binaryPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["ZEDDY_DAEMON"], !env.isEmpty {
            return env
        }
        if let self = ProcessInfo.processInfo.arguments.first {
            let sibling = (self as NSString).deletingLastPathComponent
                .appending("/zeddy-daemon")
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        let home = (NSHomeDirectory() as NSString).appendingPathComponent(".zeddy/bin/zeddy-daemon")
        if FileManager.default.isExecutableFile(atPath: home) { return home }
        return nil
    }

    public static func isRunning() -> Bool {
        FileManager.default.fileExists(atPath: Paths.daemonSocketPath)
    }

    /// Launch the daemon detached. Returns `false` if it is already running.
    @discardableResult
    public static func start() throws -> Bool {
        guard !isRunning() else { return false }
        guard let bin = binaryPath() else { throw DaemonControlError.noBinary }
        try Paths.ensureLayout()
        try spawnDetached(executable: bin, logPath: Paths.logFile)
        return true
    }

    /// Terminate the running daemon (SIGTERM).
    public static func stop() throws {
        _ = try? run("/usr/bin/pkill", ["-x", "zeddy-daemon"])
    }

    // MARK: - Process plumbing

    private static func run(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// `posix_spawn` with `POSIX_SPAWN_SETSID` so the daemon runs in its own
    /// session and survives the caller exiting or the controlling terminal
    /// closing. Stdin/stdout go to `/dev/null`; stderr to the daemon log.
    private static func spawnDetached(executable: String, logPath: String) throws {
        let devNull = open("/dev/null", O_RDWR)
        let log = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        defer {
            if devNull >= 0 { close(devNull) }
            if log >= 0 { close(log) }
        }
        guard devNull >= 0, log >= 0 else {
            throw DaemonControlError.spawnFailed(Int32(errno))
        }

        // `posix_spawnattr_t` / `posix_spawn_file_actions_t` are opaque C pointer
        // typedefs. Declare them as optionals; the `init`/`destroy` calls take
        // `&` (a pointer to the optional) and `posix_spawn` takes `&` too.
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        // POSIX_SPAWN_SETSID → the daemon runs in its own session and survives
        // the caller exiting or the controlling terminal closing.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        posix_spawn_file_actions_adddup2(&actions, devNull, 0)
        posix_spawn_file_actions_adddup2(&actions, devNull, 1)
        posix_spawn_file_actions_adddup2(&actions, log, 2)

        // `posix_spawn` wants a *mutable*, null-terminated C string for both
        // `file` and `argv[0]` (a `String`'s `utf8String` is immutable). Copy
        // the path into a zero-terminated buffer and reuse it for both.
        var pathBuf = [UInt8](repeating: 0, count: executable.utf8.count + 1)
        executable.withCString { cstr in
            pathBuf.withUnsafeMutableBytes { dst in
                if let d = dst.baseAddress {
                    d.copyMemory(from: cstr, byteCount: executable.utf8.count)
                }
            }
        }

        var pid: pid_t = 0
        let rc = pathBuf.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Int32 in
            let cstr = buf.baseAddress!.assumingMemoryBound(to: CChar.self)
            var cArgs = [cstr, nil]
            return posix_spawn(&pid, cstr, &actions, &attr, &cArgs, environ)
        }
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&actions)
        if rc != 0 { throw DaemonControlError.spawnFailed(rc) }

        // Reap any early exit so the detached child is not left as a zombie.
        waitpid(pid, nil, WNOHANG)
    }
}
