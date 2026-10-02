import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A newline-delimited JSON client for the Zeddy daemon.
///
/// Mirrors `SocketServer` on the caller side: connect to the Unix socket, write
/// a single `IPC.Frame`, and read back the matching `IPC.Response`. One
/// request per connection keeps the API trivially correct and maps onto the
/// daemon's per-connection handler.

public final class SocketClient: Sendable {
    private let socketPath: String
    private let readTimeout: Double

    public init(socketPath: String = Paths.daemonSocketPath, readTimeout: Double = 5.0) {
        self.socketPath = socketPath
        self.readTimeout = readTimeout
    }

    /// Send one request and return the daemon's response.
    ///
    /// Throws `SocketClientError` on transport problems; a logically-failed
    /// request is still a successful round-trip and is returned with `ok == false`.
    public func request(_ frame: IPC.Frame) throws -> IPC.Response {
        let fd = try connect()
        defer { close(fd) }

        let out = IPC.encodeFrame(frame)
        try sendAll(fd, out)

        // A wall-clock deadline bounds the total wait, while `.wouldBlock` lets
        // us keep reaping a response that arrives across several recv() calls.
        let start = Date()
        var buffer = Data()
        while true {
            switch try readLine(fd, buffer: &buffer) {
            case .line(let data):
                if let response = try? IPC.decoder.decode(IPC.Response.self, from: data) {
                    return response
                }
                // A non-JSON line is not our response; keep draining.
            case .peerClosed:
                throw SocketClientError.noResponse
            case .wouldBlock:
                if Date().timeIntervalSince(start) >= readTimeout {
                    throw SocketClientError.noResponse
                }
            }
        }
    }

    // MARK: - Transport

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError.badSocket(errno) }

        // A short per-recv poll so a slow or split response can be reaped over
        // several recv() calls; the request() wall-clock deadline bounds the total.
        var deadline = timeval()
        let poll = min(0.25, max(0.0, readTimeout))
        deadline.tv_sec = Int(poll)
        deadline.tv_usec = Int32((poll - Double(Int(poll))) * 1_000_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < (MemoryLayout<sockaddr_un>.size - 2) else {
            close(fd)
            throw SocketClientError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { (buf: UnsafeMutableRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            pathBytes.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                base.copyMemory(from: srcBase, byteCount: src.count)
            }
            base.assumingMemoryBound(to: UInt8.self)[pathBytes.count] = 0
        }

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            close(fd)
            throw SocketClientError.connectFailed(code)
        }
        return fd
    }

    private func sendAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes {
                send(fd, $0.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard n > 0 else {
                let code = errno
                throw SocketClientError.sendFailed(code)
            }
            sent += n
        }
    }

    /// Outcome of one `readLine` pass.
    private enum ReadOutcome {
        case line(Data)
        case wouldBlock
        case peerClosed
    }

    /// Read one complete newline-terminated line, buffering across recv() calls.
    /// Returns `.line` when the buffer holds a complete line; otherwise reports
    /// whether more data may still arrive (`.wouldBlock`) or the peer is gone
    /// (`.peerClosed`).
    private func readLine(_ fd: Int32, buffer: inout Data) throws -> ReadOutcome {
        if let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<idx)
            buffer = buffer.subdata(in: (idx + 1)..<buffer.endIndex)
            return .line(line)
        }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let n = recv(fd, &chunk, chunk.count, 0)
        if n < 0 {
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK {
                return .wouldBlock
            }
            throw SocketClientError.readFailed(code)
        }
        if n == 0 { return .peerClosed } // peer closed
        buffer.append(contentsOf: chunk[0..<n])
        return .wouldBlock
    }
}

public enum SocketClientError: Error, CustomStringConvertible {
    case badSocket(Int32)
    case pathTooLong
    case connectFailed(Int32)
    case sendFailed(Int32)
    case readFailed(Int32)
    case noResponse

    public var description: String {
        switch self {
        case .badSocket(let c): return "socket() failed (\(c))"
        case .pathTooLong: return "socket path too long"
        case .connectFailed(let c): return "connect failed (\(codeMessage(c)))"
        case .sendFailed(let c): return "send failed (\(codeMessage(c)))"
        case .readFailed(let c): return "read failed (\(codeMessage(c)))"
        case .noResponse: return "no response from daemon"
        }
    }

    private func codeMessage(_ c: Int32) -> String {
        if let ptr = strerror(c) { return "\(c): \(String(cString: ptr))" }
        return String(c)
    }
}
