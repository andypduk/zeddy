import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Starts and stops the standalone daemon without relying on broad process-name matching.
public enum DaemonControl {
    public enum Error: Swift.Error, CustomStringConvertible {
        case daemonBinaryNotFound
        case launchFailed(String)

        public var description: String {
            switch self {
            case .daemonBinaryNotFound: return "zeddy-daemon binary not found; set ZEDDY_DAEMON to its executable path"
            case .launchFailed(let message): return "could not start zeddy-daemon: \(message)"
            }
        }
    }

    public static func binaryPath() -> String? {
        if let path = ProcessInfo.processInfo.environment["ZEDDY_DAEMON"], FileManager.default.isExecutableFile(atPath: path) { return path }
        if let executable = CommandLine.arguments.first {
            let sibling = (executable as NSString).deletingLastPathComponent + "/zeddy-daemon"
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        let bundlePath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeddy-daemon").path
        if FileManager.default.isExecutableFile(atPath: bundlePath) { return bundlePath }
        let userLocal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/zeddy-daemon").path
        if FileManager.default.isExecutableFile(atPath: userLocal) { return userLocal }
        let systemCandidates = [
            "/usr/local/bin/zeddy-daemon",
            "/opt/homebrew/bin/zeddy-daemon",
            FileManager.default.currentDirectoryPath + "/.build/release/zeddy-daemon",
            FileManager.default.currentDirectoryPath + "/.build/debug/zeddy-daemon",
            Paths.base.appendingPathComponent("bin/zeddy-daemon").path
        ]
        for candidate in systemCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func isRunning() -> Bool {
        guard let raw = try? String(contentsOfFile: Paths.pidFile), let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid, 0) == 0
    }

    @discardableResult
    public static func start() throws -> Bool {
        if isRunning() { return false }
        guard let binary = binaryPath() else { throw Error.daemonBinaryNotFound }
        try Paths.ensureLayout()

        // Clean stale socket and pid from prior runs
        try? FileManager.default.removeItem(atPath: Paths.daemonSocketPath)
        try? FileManager.default.removeItem(atPath: Paths.pidFile)
        FileManager.default.createFile(atPath: Paths.logFile, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: Paths.logFile))
        do { try process.run() } catch { throw Error.launchFailed(error.localizedDescription) }

        let client = DaemonClient(timeout: 1)
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: Paths.daemonSocketPath) {
                // Ensure socket is actually answering requests
                if let res = try? client.call("version"), res.ok {
                    return true
                }
            }
            usleep(50_000)
        }
        if FileManager.default.fileExists(atPath: Paths.daemonSocketPath) {
            return true
        }
        throw Error.launchFailed("process did not create its socket; see \(Paths.logFile)")
    }

    public static func stop() throws {
        if let raw = try? String(contentsOfFile: Paths.pidFile), let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
            for _ in 0..<20 {
                if kill(pid, 0) != 0 { break }
                usleep(50_000)
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(atPath: Paths.pidFile)
        try? FileManager.default.removeItem(atPath: Paths.daemonSocketPath)
    }
}
