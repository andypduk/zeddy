import Foundation

/// The daemon's wire protocol: newline-delimited JSON over the Unix socket.
///
/// Each line is a `Frame` (a request) or a `Response` (a reply). `data` is a
/// free-form `JSONValue` so the protocol stays open: a method's payload/shape is
/// documented by convention (see `Models.swift` and `MemoryEngine.handle`).
public enum IPC {
    /// Well-known method names.
    public enum Method: String, Codable, Sendable {
        case status
        case remember
        case get
        case delete
        case search
        case list
        case buildContext
        case markUsed
        case prune
        case getSettings
        case setSettings
        case export
        case import

        public var rawValue: String {
            switch self {
            case .status: return "status"
            case .remember: return "remember"
            case .get: return "get"
            case .delete: return "delete"
            case .search: return "search"
            case .list: return "list"
            case .buildContext: return "build_context"
            case .markUsed: return "mark_used"
            case .prune: return "prune"
            case .getSettings: return "get_settings"
            case .setSettings: return "set_settings"
            case .export: return "export"
            case .import: return "import"
            }
        }
    }

    /// A single JSON value. Encodes/decodes as its JSON shape, which keeps the
    /// protocol self-describing without a per-method schema.
    public enum JSONValue: Codable, Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
            else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
            else { self = .null }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .number(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }

        public var string: String? { if case .string(let s) = self { return s }; return nil }
        public var number: Double? { if case .number(let n) = self { return n }; return nil }
        public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    }

    /// A request frame (daemon consumes these).
    public struct Frame: Codable, Sendable {
        public var method: Method
        public var data: JSONValue?
        public init(method: Method, data: JSONValue? = nil) {
            self.method = method
            self.data = data
        }
    }

    /// A response frame (daemon sends these; clients decode them).
    public struct Response: Codable, SerializeError, Sendable {
        public var ok: Bool
        public var error: String?
        public var data: JSONValue?

        public init(ok: Bool = true, error: String? = nil, data: JSONValue? = nil) {
            self.ok = ok
            self.error = error
            self.data = data
        }

        /// `data` decoded into a concrete `Codable` type (nil if absent/failed).
        public func decodeData<T: Codable>(_ type: T.Type) -> T? {
            guard let data else { return nil }
            guard let raw = try? IPC.encoder.encode(data) else { return nil }
            return try? IPC.decoder.decode(T.self, from: raw)
        }
    }

    /// Shared encoders so frames and payloads serialize consistently.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()
    public static let decoder: JSONDecoder = JSONDecoder()

    /// Serialize a response to a single newline-terminated frame (one per line).
    public static func encodeFrame(_ resp: Response) -> Data? {
        guard let d = try? encoder.encode(resp) else { return nil }
        var d = d
        d.append(0x0A) // '\n'
        return d
    }

    /// Serialize a request frame to a single newline-terminated line.
    public static func encodeRequestFrame(_ frame: Frame) -> Data? {
        guard let d = try? encoder.encode(frame) else { return nil }
        var d = d
        d.append(0x0A)
        return d
    }

    /// Parse the next complete line from `buffer` as a `Frame`, if one is ready.
    public static func readFrame(from buffer: inout [UInt8]) -> Frame? {
        if let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<idx]
            buffer.removeSubrange(..<idx)
            if line.isEmpty { return nil }
            let data = Data(line)
            return try? decoder.decode(Frame.self, from: data)
        }
        return nil
    }

    /// Parse the next complete line from `buffer` as a `Response`, if one is ready.
    public static func readResponse(from buffer: inout [UInt8]) -> Response? {
        if let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<idx]
            buffer.removeSubrange(..<idx)
            if line.isEmpty { return nil }
            return try? decoder.decode(Response.self, from: Data(line))
        }
        return nil
    }
}

/// The status snapshot returned by the `status` method — surfaced in the GUI
/// footer/daemon pane and the CLI.
public struct DaemonStatus: Codable, Sendable {
    public var version: String?
    public var socketPath: String
    public var settings: ZeddySettings
    public var store: MemoryStore.StoreStatus
    public var uptimeSeconds: Double

    public init(version: String?, socketPath: String, settings: ZeddySettings,
                store: MemoryStore.StoreStatus, uptimeSeconds: Double) {
        self.version = version
        self.socketPath = socketPath
        self.settings = settings
        self.store = store
        self.uptimeSeconds = uptimeSeconds
    }
}

/// A client-facing summary of the daemon's socket reachability (no round-trip
/// needed for the fields we can read locally).
public struct ClientStatus: Codable, Sendable {
    public var socketPath: String
    public var socketPresent: Bool

    public init(socketPath: String, socketPresent: Bool) {
        self.socketPath = socketPath
        self.socketPresent = socketPresent
    }
}
