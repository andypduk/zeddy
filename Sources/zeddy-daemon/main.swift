import Foundation
import ZeddyCore
#if canImport(Darwin)
import Darwin
#endif

func log(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: .now))] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: Paths.logFile) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}

do {
    try Paths.ensureLayout()
    FileManager.default.createFile(atPath: Paths.logFile, contents: nil)
    try String(ProcessInfo.processInfo.processIdentifier).write(toFile: Paths.pidFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: Paths.pidFile) }

    let store = try MemoryStore(path: Paths.dbFile)
    let engine = Engine(store: store, settings: SettingsStore.load())
    let server = SocketServer(socketPath: Paths.daemonSocketPath, handler: engine.dispatch)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { server.stop() }
    terminate.setEventHandler { server.stop() }
    interrupt.activate()
    terminate.activate()

    log("started: sqlite \(store.libraryVersion), socket \(Paths.daemonSocketPath)")
    try withExtendedLifetime((interrupt, terminate)) { try server.start() }
    log("stopped")
} catch {
    FileHandle.standardError.write(Data("zeddy-daemon: \(error)\n".utf8))
    exit(1)
}
