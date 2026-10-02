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
        let installed = Paths.base.appendingPathComponent("bin/zeddy-daemon").path
        return FileManager.default.isExecutableFile(atPath: installed) ? installed : nil
    }

    public static func isRunning() -> Bool {
        guard let raw = try? String(contentsOfFile: Paths.pidFile), let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return FileManager.default.fileExists(atPath: Paths.daemonSocketPath)
        }
        return kill(pid, 0) == 0
    }

    @discardableResult
    public static func start() throws -> Bool {
        guard !isRunning() else { return false }
        guard let binary = binaryPath() else { throw Error.daemonBinaryNotFound }
        try Paths.ensureLayout()
        FileManager.default.createFile(atPath: Paths.logFile, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: Paths.logFile))
        do { try process.run() } catch { throw Error.launchFailed(error.localizedDescription) }

        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: Paths.daemonSocketPath) { return true }
            usleep(50_000)
        }
        throw Error.launchFailed("process did not create its socket; see \(Paths.logFile)")
    }

    public static func stop() throws {
        guard let raw = try? String(contentsOfFile: Paths.pidFile), let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            try? FileManager.default.removeItem(atPath: Paths.daemonSocketPath)
            return
        }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw Error.launchFailed("could not signal pid \(pid)")
        }
    }
}
