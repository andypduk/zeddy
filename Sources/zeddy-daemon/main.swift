import Foundation
import ZeddyCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Daemon entry

let argv = CommandLine.arguments

if argv.contains("--daemon") {
    daemonize(logPath: Paths.logFile)
}

let engine = try MemoryEngine()
do {
    try run(engine: engine)
} catch {
    let msg = "zeddy-daemon: \(error)\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(1)
}

func run(engine: MemoryEngine) throws {
    let server = SocketServer(socketPath: Paths.daemonSocketPath) { frame in
        engine.handle(frame)
    }

    // Stop cleanly on SIGINT/SIGTERM (the CLI sends SIGTERM to stop us).
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setCancelHandler {}
    source.setEventHandler { server.stop() }
    source.activate()
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    termSource.setEventHandler { server.stop() }
    termSource.activate()

    log("zeddy-daemon starting (socket \(Paths.daemonSocketPath))")
    log("library sqlite \(engine.store.libraryVersion), schema v\(MemoryStore.schemaVersion)")
    log("pid \(ProcessInfo.processInfo.processIdentifier)")

    try server.start() // blocks until stop()

    log("zeddy-daemon stopped")
}

// MARK: - Logging

func log(_ s: String) {
    let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(s)\n"
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: Paths.logFile)) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }
}

// MARK: - Daemonization

/// Turn the freshly-launched process into a background daemon.
///
/// Single fork: the parent (the one `Process.run()` created) exits immediately
/// so the CLI can return, while the child re-parents to init via `setsid()`
/// and keeps running. The child inherits stdout/stderr already pointed at the
/// log file by the caller, and we re-point stdin at `/dev/null`.
func daemonize(logPath: String) {
    let pid = fork()
    guard pid >= 0 else {
        let msg = "zeddy-daemon: fork failed (\(String(cString: strerror(errno))))\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
        exit(1)
    }
    if pid > 0 {
        // Parent: detach and let go. Use `_exit` (not `exit`) to avoid
        // running atexit handlers / flushing the parent's stdio in the child.
        _exit(0)
    }

    // Child: become a session leader so we are fully detached from the CLI.
    _ = setsid()

    // Detach the control terminal by pointing stdin at /dev/null.
    if let devNull = open("/dev/null", O_RDWR) {
        dup2(devNull, STDIN_FILENO)
        if devNull > 2 { close(devNull) }
    }

    // Record our (post-fork) pid authoritatively. Use POSIX-only calls here:
    // in a freshly forked child we must avoid Foundation (it may hold a lock
    // inherited from the parent thread and would deadlock on a re-lock).
    let pid = getpid()
    var buf = [CChar](repeating: 0, count: 16)
    _ = snprintf(buf, buf.count, "\(pid)")
    let pidPath = Paths.base + "/daemon.pid"
    let fd = open((pidPath as NSString).utf8String, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        var off = 0
        let len = strlen(buf)
        while off < len {
            let n = write(fd, buf.advanced(by: off), len - off)
            guard n > 0 else { break }
            off += n
        }
        close(fd)
    }
}
