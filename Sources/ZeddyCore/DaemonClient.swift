import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A client that talks to the `zeddy-daemon` over its Unix socket.
///
/// One request = one request/response exchange. The daemon is the engine; this
/// is how both the CLI and the GUI reach it. The read is newline-delimited and
/// bounded by a timeout so a wedged daemon can't hang the caller.
public final class DaemonClient: @unchecked Sendable {
    private let socketPath: String
    private let timeout: TimeInterval
    private let ioQueue = DispatchQueue(label: "zeddy.daemonclient.io")

    public init(socketPath: String = Paths.daemonSocketPath, timeout: TimeInterval = 10) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// Whether the daemon socket is present on disk.
    public var isRunning: Bool {
        var statBuf = stat()
        return stat(socketPath, &statBuf) == 0
    }

    /// Send a request and wait for the matching response.
    public func call(_ method: String, _ params: [String: JSONValue] = [:], id: Int = 1) throws -> IPC.Response {
        let frame = IPC.Frame(method: method, id: id, params: params)
        return try ioQueue.sync { try self.exchange(IPC.encodeFrame(frame)) }
    }

    private func exchange(_ payload: Data) throws -> IPC.Response {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // `sun_path` is a fixed C char array imported as a tuple (no `.count`).
        // Its length is the struct size minus the 2-byte leading family header.
        let capacity = MemoryLayout<sockaddr_un>.size - 2
        guard pathBytes.count < capacity else {
            throw DaemonClientError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { (buf: UnsafeMutableRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            pathBytes.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                base.copyMemory(from: srcBase, byteCount: src.count)
            }
            base.assumingMemoryBound(to: UInt8.self)[pathBytes.count] = 0 // null-terminate
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonClientError.badSocket(errno) }
        defer { close(fd) }

        // Bounded read so a dead daemon can't hang us.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var wtv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wtv, socklen_t(MemoryLayout<timeval>.size))

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw DaemonClientError.connectFailed(errno) }

        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBytes {
                send(fd, $0.baseAddress!.advanced(by: sent), payload.count - sent, 0)
            }
            guard n > 0 else { throw DaemonClientError.writeFailed(errno) }
            sent += n
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK { break }
                throw DaemonClientError.readFailed(e)
            }
            if n == 0 { break } // peer closed
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                let head = buffer.subdata(in: buffer.startIndex..<newline)
                if let response = try? IPC.decoder.decode(IPC.Response.self, from: head) {
                    return response
                }
            }
        }
        // Drain anything left before the socket closed.
        if let newline = buffer.firstIndex(of: 0x0A) {
            let head = buffer.subdata(in: buffer.startIndex..<newline)
            if let response = try? IPC.decoder.decode(IPC.Response.self, from: head) {
                return response
            }
        }
        throw DaemonClientError.noResponse
    }
}

public enum DaemonClientError: Error, CustomStringConvertible {
    case socketPathTooLong
    case badSocket(Int32)
    case connectFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case noResponse

    public var description: String {
        switch self {
        case .socketPathTooLong: return "socket path too long"
        case .badSocket(let c): return "socket() failed (\(c))"
        case .connectFailed(let c): return "connect() failed (\(c)) — is the daemon running?"
        case .writeFailed(let c): return "write failed (\(c))"
        case .readFailed(let c): return "read failed (\(c))"
        case .noResponse: return "no response from daemon (timeout or closed)"
        }
    }
}
