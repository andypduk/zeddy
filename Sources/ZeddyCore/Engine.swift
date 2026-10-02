import Foundation

/// The application engine. It owns a `MemoryStore` and exposes the operations
/// both the daemon and the GUI need, plus a `dispatch` entry point that is used
/// verbatim over IPC and in-process.
///
/// Keeping this as the single source of logic means the daemon is a thin socket
/// shell and the GUI can run identically without it.
public final class Engine: @unchecked Sendable {
    private let store: MemoryStore
    private let lock = NSLock()
    private var settings: ZeddySettings

    public var socketPath: String { Paths.daemonSocketPath }

    public init(store: MemoryStore, settings: ZeddySettings = .default) {
        self.store = store
        self.settings = settings
    }

    public func loadSettings() -> ZeddySettings { SettingsStore.load() }

    public func saveSettings(_ s: ZeddySettings) throws {
        try SettingsStore.save(s)
        lock.lock(); settings = s; lock.unlock()
    }

    public func currentSettings() -> ZeddySettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    // MARK: - Store operations

    public func version() -> String {
        let db = store.libraryVersion
        return "zeddy 1.0.0 (sqlite \(db))"
    }

    public func stats() throws -> MemoryStore.Stats { try store.stats() }

    public func list(kind: Memory.Kind? = nil, projectPath: String? = nil) throws -> [Memory] {
        try store.list(kind: kind, projectPath: projectPath)
    }

    public func get(_ id: String) throws -> Memory? { try store.get(id) }

    @discardableResult
    public func add(_ memory: Memory) throws -> Memory {
        try store.upsert(memory)
        return memory
    }

    @discardableResult
    public func update(_ memory: Memory) throws -> Memory {
        try store.upsert(memory)
        return memory
    }

    @discardableResult
    public func delete(_ id: String) throws -> Bool { try store.delete(id) }

    public func search(_ q: String, kind: Memory.Kind? = nil, projectPath: String? = nil, limit: Int = 8) throws -> [SearchHit] {
        try store.search(q, kind: kind, projectPath: projectPath, limit: limit)
    }

    @discardableResult
    public func prune(olderThanDays: Int) throws -> Int { try store.pruneUnused(olderThanDays: olderThanDays) }

    public func buildContext(prompt: String, projectPath: String?) throws -> ContextBlock {
        try ContextBuilder.build(prompt: prompt, projectPath: projectPath, store: store, settings: currentSettings())
    }

    public func exportJSON() throws -> Data { try store.allJSON() }

    @discardableResult
    public func importJSON(_ data: Data) throws -> Int { try store.importJSON(data) }

    // MARK: - IPC dispatch

    /// Execute a named request. Shared verbatim by the daemon and the app.
    public func dispatch(_ frame: IPC.Frame) -> IPC.Response {
        do {
            switch frame.method {
            case "version":
                return ok(frame.id, JSONValue.string(version()))
            case "status":
                let s = try stats()
                return ok(frame.id, JSONValue.encode(s))
            case "stats":
                return ok(frame.id, JSONValue.encode(try stats()))
            case "list":
                let kind = frame.params["kind"].flatMap { $0.stringValue }.flatMap(Memory.Kind.init(rawValue:))
                let project = frame.params["projectPath"]?.stringValue
                return ok(frame.id, JSONValue.array(try list(kind: kind, projectPath: project).map { JSONValue.encode($0) }))
            case "get":
                guard let id = frame.params["id"]?.stringValue else { throw EngineError.missing("id") }
                if let m = try get(id) { return ok(frame.id, JSONValue.encode(m)) }
                return fail(frame.id, "not found")
            case "add":
                guard let payload = decodeParams(AddPayload.self, frame.params) else {
                    throw EngineError.missing("memory")
                }
                return ok(frame.id, JSONValue.encode(try add(payload.toMemory())))
            case "update":
                guard let payload = decodeParams(UpdatePayload.self, frame.params) else {
                    throw EngineError.missing("id")
                }
                guard var memory = try get(payload.id) else { return fail(frame.id, "not found") }
                // Partial update: only provided fields change.
                if let t = payload.title { memory.title = t }
                if let c = payload.content { memory.content = c }
                if let k = payload.kind { memory.kind = k }
                if let pp = payload.projectPath { memory.projectPath = pp }
                if let tags = payload.tags { memory.tags = tags }
                return ok(frame.id, JSONValue.encode(try update(memory)))
            case "delete":
                guard let id = frame.params["id"]?.stringValue else { throw EngineError.missing("id") }
                return ok(frame.id, JSONValue.bool(try delete(id)))
            case "search":
                guard let q = frame.params["q"]?.stringValue else { throw EngineError.missing("q") }
                let kind = frame.params["kind"].flatMap { $0.stringValue }.flatMap(Memory.Kind.init(rawValue:))
                let project = frame.params["projectPath"]?.stringValue
                let limit = frame.params["limit"]?.intValue ?? 8
                return ok(frame.id, JSONValue.array(try search(q, kind: kind, projectPath: project, limit: limit).map { JSONValue.encode($0) }))
            case "prune":
                let days = frame.params["olderThanDays"]?.intValue ?? 90
                return ok(frame.id, JSONValue.int(try prune(olderThanDays: days)))
            case "build_context":
                guard let prompt = frame.params["prompt"]?.stringValue else { throw EngineError.missing("prompt") }
                let project = frame.params["projectPath"]?.stringValue
                return ok(frame.id, JSONValue.encode(try buildContext(prompt: prompt, projectPath: project)))
            case "export":
                let data = try exportJSON()
                let base64 = data.base64EncodedString()
                return ok(frame.id, JSONValue.string(base64))
            case "import":
                guard let b64 = frame.params["data"]?.stringValue,
                      let data = Data(base64Encoded: b64) else { throw EngineError.missing("data") }
                return ok(frame.id, JSONValue.int(try importJSON(data)))
            case "settings":
                return ok(frame.id, JSONValue.encode(currentSettings()))
            case "update_settings":
                var s = currentSettings()
                if let total = frame.params["totalTokens"]?.intValue { s.budget.totalTokens = total }
                if let ratio = frame.params["projectRatio"]?.doubleValue { s.budget.projectRatio = ratio }
                if let interval = frame.params["indexRefreshInterval"]?.doubleValue { s.indexRefreshInterval = interval }
                if let minScore = frame.params["minScore"]?.doubleValue { s.minScore = minScore }
                try saveSettings(s)
                return ok(frame.id, JSONValue.encode(s))
            default:
                return fail(frame.id, "unknown method: \(frame.method)")
            }
        } catch let e as EngineError {
            return fail(frame.id, e.description)
        } catch {
            return fail(frame.id, "\(error)")
        }
    }

    private func ok(_ id: Int, _ data: JSONValue) -> IPC.Response {
        IPC.Response(ok: true, id: id, data: data)
    }

    private func fail(_ id: Int, _ message: String) -> IPC.Response {
        IPC.Response(ok: false, id: id, error: message)
    }

    /// Decode a typed payload from a frame's `params` blob. `JSONValue`
    /// preserves `Double`/`Int` through the round-trip, so dates and counters
    /// survive; a client that omits optional fields still decodes (they become
    /// `nil`).
    private func decodeParams<T: Decodable>(_ type: T.Type, _ params: [String: JSONValue]) -> T? {
        guard let data = try? IPC.encoder.encode(params) else { return nil }
        return try? IPC.decoder.decode(type, from: data)
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case missing(String)
    public var description: String {
        switch self {
        case .missing(let s): return "missing parameter: \(s)"
        }
    }
}

// Convenience typed getters over JSONValue.
extension JSONValue {
    public var stringValue: String? {
        switch self { case .string(let s): return s; case .int(let i): return String(i); case .double(let d): return String(d); default: return nil }
    }
    public var intValue: Int? {
        switch self { case .int(let i): return i; case .double(let d): return Int(d); case .string(let s): return Int(s); default: return nil }
    }
    public var doubleValue: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); case .string(let s): return Double(s); default: return nil }
    }
    public var boolValue: Bool? {
        switch self { case .bool(let b): return b; case .string(let s): return s == "true" ? true : (s == "false" ? false : nil); default: return nil }
    }
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
