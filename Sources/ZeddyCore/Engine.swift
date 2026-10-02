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
    private let usageTracker: UsageTracker

    public var socketPath: String { Paths.daemonSocketPath }

    public init(store: MemoryStore, settings: ZeddySettings = .default, usageTracker: UsageTracker = .shared) {
        self.store = store
        self.settings = settings
        self.usageTracker = usageTracker
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
        let startTime = Date()
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
                let mem = try add(payload.toMemory())
                let elapsedMs = Date().timeIntervalSince(startTime) * 1000
                usageTracker.record(
                    method: "add",
                    promptSnippet: String(mem.title.prefix(80)),
                    injectedTokens: 0,
                    budgetTokens: 0,
                    estimatedSavedTokens: 0,
                    durationMs: elapsedMs,
                    status: "success",
                    memoryTitles: [mem.title]
                )
                return ok(frame.id, JSONValue.encode(mem))
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
                let updated = try update(memory)
                let elapsedMs = Date().timeIntervalSince(startTime) * 1000
                usageTracker.record(
                    method: "update",
                    promptSnippet: String(updated.title.prefix(80)),
                    durationMs: elapsedMs,
                    status: "success",
                    memoryTitles: [updated.title]
                )
                return ok(frame.id, JSONValue.encode(updated))
            case "delete":
                guard let id = frame.params["id"]?.stringValue else { throw EngineError.missing("id") }
                let deleted = try delete(id)
                let elapsedMs = Date().timeIntervalSince(startTime) * 1000
                usageTracker.record(
                    method: "delete",
                    promptSnippet: id,
                    durationMs: elapsedMs,
                    status: deleted ? "success" : "not_found"
                )
                return ok(frame.id, JSONValue.bool(deleted))
            case "search":
                guard let q = frame.params["q"]?.stringValue ?? frame.params["text"]?.stringValue else { throw EngineError.missing("q") }
                let kind = frame.params["kind"].flatMap { $0.stringValue }.flatMap(Memory.Kind.init(rawValue:))
                let project = frame.params["projectPath"]?.stringValue
                let limit = frame.params["limit"]?.intValue ?? 8
                let hits = try search(q, kind: kind, projectPath: project, limit: limit)
                let elapsedMs = Date().timeIntervalSince(startTime) * 1000
                let totalTok = hits.reduce(0) { $0 + TokenEstimator.estimate($1.memory.content) }
                usageTracker.record(
                    method: "search",
                    promptSnippet: String(q.prefix(80)),
                    injectedTokens: totalTok,
                    budgetTokens: 0,
                    estimatedSavedTokens: hits.count * 200,
                    durationMs: elapsedMs,
                    status: hits.isEmpty ? "empty" : "hit",
                    memoryTitles: hits.map { $0.memory.title }
                )
                return ok(frame.id, JSONValue.array(hits.map { JSONValue.encode($0) }))
            case "prune":
                let days = frame.params["olderThanDays"]?.intValue ?? 90
                return ok(frame.id, JSONValue.int(try prune(olderThanDays: days)))
            case "build_context":
                guard let prompt = frame.params["prompt"]?.stringValue else { throw EngineError.missing("prompt") }
                let project = frame.params["projectPath"]?.stringValue
                let block = try buildContext(prompt: prompt, projectPath: project)
                let elapsedMs = Date().timeIntervalSince(startTime) * 1000
                let titles: [String] = block.usedIds.compactMap { id in
                    if let m = try? self.get(id) { return m.title }
                    return nil
                }
                // Calculate estimated saved tokens vs uncompressed prompt context
                let saved = max(0, (block.budgetTokens - block.usedTokens) + (block.usedIds.count * 350))
                usageTracker.record(
                    method: "build_context",
                    promptSnippet: String(prompt.prefix(80)),
                    injectedTokens: block.usedTokens,
                    budgetTokens: block.budgetTokens,
                    estimatedSavedTokens: saved,
                    durationMs: elapsedMs,
                    status: block.usedTokens > 0 ? "hit" : "empty",
                    memoryTitles: titles
                )
                return ok(frame.id, JSONValue.encode(block))
            case "usage_stats":
                let period = frame.params["period"]?.stringValue ?? "live"
                let s = usageTracker.stats(period: period)
                return ok(frame.id, JSONValue.encode(s))
            case "usage_logs":
                let limit = frame.params["limit"]?.intValue ?? 50
                let logs = usageTracker.recentLogs(limit: limit)
                return ok(frame.id, JSONValue.array(logs.map { JSONValue.encode($0) }))
            case "usage_clear":
                usageTracker.clear()
                return ok(frame.id, JSONValue.bool(true))
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
                guard let s = decodeParams(ZeddySettings.self, frame.params) else {
                    throw EngineError.missing("settings")
                }
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


