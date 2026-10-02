import Foundation

/// The single piece of logic the daemon executes for each request.
///
/// It is deliberately a thin dispatch over `MemoryStore` + `ContextBuilder` +
/// `Settings`: all the heavy lifting (FTS search, BM25 ranking, token budgeting,
/// context assembly) lives in those collaborators, so this stays easy to read
/// and easy to test. It is the one function the whole system hinges on.
public final class MemoryEngine: @unchecked Sendable {
    public let store: MemoryStore
    public let settings: Settings
    private let startedAt = Date()

    public init(store: MemoryStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    /// Handle a request frame and return a response frame.
    public func handle(_ frame: IPC.Frame) -> IPC.Response {
        let value = frame.data
        do {
            switch frame.method {
            case .status:
                let snap = DaemonStatus(
                    version: "1.0.0",
                    socketPath: Paths.daemonSocketPath,
                    settings: settings.snapshot,
                    store: try store.status(),
                    uptimeSeconds: Date().timeIntervalSince(startedAt)
                )
                let j = try JSONValue(fromCodable: snap)
                return IPC.Response(ok: true, data: j)

            case .remember:
                guard let mem = try decode(value, Memory.self) else {
                    return IPC.Response(ok: false, error: "remember requires a memory payload")
                }
                try store.upsert(mem)
                let j = try JSONValue(fromCodable: mem)
                return IPC.Response(ok: true, data: j)

            case .get:
                guard let id = try decode(value, UUID.self) else {
                    return IPC.Response(ok: false, error: "get requires a UUID payload")
                }
                if let m = try store.get(id.uuidString) {
                    let j = try JSONValue(fromCodable: m)
                    return IPC.Response(ok: true, data: j)
                }
                return IPC.Response(ok: false, error: "memory not found: \(id)")

            case .delete:
                guard let id = try decode(value, String.self) else {
                    return IPC.Response(ok: false, error: "delete requires a string id")
                }
                let removed = try store.delete(id)
                if removed {
                    return IPC.Response(ok: true, data: try JSONValue(fromCodable: true))
                }
                return IPC.Response(ok: false, error: "memory not found: \(id)")

            case .search:
                let p = try decode(value, SearchPayload.self) ?? SearchPayload(query: "")
                let hits = try store.search(p.query, kind: p.kind, projectPath: p.projectPath, limit: p.limit)
                let j = try JSONValue(fromCodable: hits)
                return IPC.Response(ok: true, data: j)

            case .list:
                let p = try decode(value, ListPayload.self) ?? ListPayload()
                let rows = try store.list(kind: p.kind, projectPath: p.projectPath, tag: p.tag)
                    .map { ListRow(memory: $0) }
                let j = try JSONValue(fromCodable: rows)
                return IPC.Response(ok: true, data: j)

            case .buildContext:
                let p = try decode(value, BuildContextPayload.self) ?? BuildContextPayload(prompt: "")
                let overrides = TokenBudgeted.Overrides(
                    maxMemories: p.maxMemories,
                    maxTokens: p.maxTokens,
                    topMemoryTokens: p.topMemoryTokens
                )
                let b = ContextBuilder(
                    budget: settings.budget,
                    overrides: overrides,
                    prompt: p.prompt,
                    projectPath: p.projectPath,
                    includeProject: settings.includeProject,
                    includeGlobal: settings.includeGlobal,
                    minScore: settings.minScore
                )
                let r = try b.build(store: store)
                let j = try JSONValue(fromCodable: r)
                return IPC.Response(ok: true, data: j)
                // The selected memories were injected; record usage so the
                // "used" bookkeeping drives pruning and ranking.
                // (Kept best-effort so a failure never breaks context building.)
                _ = try? store.markUsed(r.selectedIDs)

            case .markUsed:
                guard let ids = try decode(value, [UUID].self) else { return IPC.Response(ok: false, error: "bad payload") }
                try store.markUsed(ids.map { $0.uuidString })
                return IPC.Response(ok: true)

            case .prune:
                let p = try decode(value, PrunePayload.self) ?? PrunePayload(days: 30)
                let n = try store.pruneUnused(olderThanDays: p.days)
                let j = try JSONValue(fromCodable: n)
                return IPC.Response(ok: true, data: j)

            case .getSettings:
                let j = try JSONValue(fromCodable: settings.snapshot)
                return IPC.Response(ok: true, data: j)

            case .setSettings:
                guard let s = try decode(value, ZeddySettings.self) else {
                    return IPC.Response(ok: false, error: "bad settings payload")
                }
                try settings.apply(s)
                let j = try JSONValue(fromCodable: settings.snapshot)
                return IPC.Response(ok: true, data: j)

            case .export:
                let data = try store.allJSON()
                let j = try JSONValue(fromCodable: data.base64EncodedString())
                return IPC.Response(ok: true, data: j)

            case .import:
                guard let b64 = try decode(value, String.self) else {
                    return IPC.Response(ok: false, error: "import requires base64 payload")
                }
                guard let data = Data(base64Encoded: b64) else {
                    return IPC.Response(ok: false, error: "invalid base64")
                }
                let n = try store.importJSON(data)
                let j = try JSONValue(fromCodable: n)
                return IPC.Response(ok: true, data: j)
            }
        } catch let e as ZeddyError {
            return IPC.Response(ok: false, error: e.description)
        } catch {
            return IPC.Response(ok: false, error: error.localizedDescription)
        }
    }

    // MARK: - decode helper

    /// Decode a `JSONValue` payload into a concrete `Codable` type.
    private func decode<T: Codable>(_ value: IPC.JSONValue?, _ type: T.Type) throws -> T {
        guard let value else { throw ZeddyError.badRequest("payload required") }
        guard let raw = try IPC.encoder.encode(value) else { throw ZeddyError.badRequest("unencodable payload") }
        return try IPC.decoder.decode(T.self, from: raw)
    }
}

extension ListRow {
    public init(memory: Memory) {
        self.init(
            id: memory.id.uuidString,
            kind: memory.kind,
            title: memory.title,
            projectPath: memory.projectPath,
            tags: memory.tags,
            createdAt: memory.createdAt,
            lastUsedAt: memory.lastUsedAt,
            useCount: memory.useCount
        )
    }
}
