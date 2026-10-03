import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A Unix-socket server that speaks the newline-delimited JSON `IPC.Frame`
/// protocol. Each accepted connection is served on a private queue, so clients
/// get request/response semantics while the engine is reached one caller at a
/// time (the engine serializes its own mutations via the store's lock).
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = (IPC.Frame) -> IPC.Response

    private let socketPath: String
    private let handler: Handler
    private let ioQueue = DispatchQueue(label: "zeddy.daemon.io")
    private var listenFD: Int32 = -1
    private var running = false

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// Binds the socket and blocks in the accept loop until `stop()` is called
    /// (typically from a signal handler).
    public func start() throws {
        // Remove a stale socket from a previous (crashed) run.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.badSocket(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // `sun_path` is a fixed C char array imported as a tuple, so it has no
        // `.count`. Its length is the struct size minus the 2-byte leading
        // `sun_len`/`sun_family` header (104 on macOS, 108 on Linux).
        let capacity = MemoryLayout<sockaddr_un>.size - 2
        guard pathBytes.count < capacity else {
            close(fd)
            throw SocketServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { (buf: UnsafeMutableRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            pathBytes.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                base.copyMemory(from: srcBase, byteCount: src.count)
            }
            base.assumingMemoryBound(to: UInt8.self)[pathBytes.count] = 0 // null-terminate
        }

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else {
            close(fd)
            throw SocketServerError.bindFailed(errno)
        }

        guard Darwin.listen(fd, 16) == 0 else {
            close(fd)
            throw SocketServerError.listenFailed(errno)
        }

        listenFD = fd
        running = true
        acceptLoop()
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if !running { break }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [handler] in
                self.serveClient(fd: clientFD, handler: handler)
            }
        }
    }

    /// Handle a single client: read frames, respond to each, until it closes.
    private func serveClient(fd: Int32, handler: Handler) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while running {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 { break }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            // Process every complete frame currently buffered.
            while let newline = buffer.firstIndex(of: 0x0A) {
                let head = buffer.subdata(in: buffer.startIndex..<newline)
                let rest = buffer.subdata(in: (newline + 1)..<buffer.endIndex)
                buffer = rest
                if let frame = try? IPC.decoder.decode(IPC.Frame.self, from: head) {
                    let response = handler(frame)
                    let payload = IPC.encodeFrame(response)
                    var sent = 0
                    while sent < payload.count {
                        let r = payload.withUnsafeBytes {
                            send(fd, $0.baseAddress!.advanced(by: sent), payload.count - sent, 0)
                        }
                        guard r > 0 else { return }
                        sent += r
                    }
                }
            }
        }
    }
}

public enum SocketServerError: Error, CustomStringConvertible {
    case badSocket(Int32)
    case pathTooLong
    case bindFailed(Int32)
    case listenFailed(Int32)

    public var description: String {
        switch self {
        case .badSocket(let c): return "socket() failed (\(c))"
        case .pathTooLong: return "socket path too long"
        case .bindFailed(let c): return "bind() failed (\(c))"
        case .listenFailed(let c): return "listen() failed (\(c))"
        }
    }
}
