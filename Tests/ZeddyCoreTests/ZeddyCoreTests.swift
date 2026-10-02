import XCTest
@testable import ZeddyCore

final class ZeddyCoreTests: XCTestCase {
    private func makeStore() throws -> (MemoryStore, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zeddy-tests-\(UUID().uuidString).db")
        return (try MemoryStore(path: file.path), file)
    }

    private func removeDatabase(_ file: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
    }

    func testCRUDAndScopeFilters() throws {
        let (store, file) = try makeStore()
        defer { removeDatabase(file) }
        let global = Memory(title: "Global convention", content: "Use Swift concurrency.")
        let project = Memory(kind: .project, title: "Project convention", content: "Use FTS5 for search.", projectPath: "/tmp/project")
        try store.upsert(global)
        try store.upsert(project)

        let loaded = try XCTUnwrap(store.get(global.id.uuidString))
        XCTAssertEqual(loaded.id, global.id)
        XCTAssertEqual(loaded.title, global.title)
        XCTAssertEqual(loaded.content, global.content)
        XCTAssertEqual(try store.list(kind: .global).map(\.id), [global.id])
        XCTAssertEqual(try store.list(kind: .project, projectPath: "/tmp/project").map(\.id), [project.id])
        XCTAssertTrue(try store.delete(global.id.uuidString))
        XCTAssertNil(try store.get(global.id.uuidString))
    }

    func testBM25ReturnsPositiveRelevance() throws {
        let (store, file) = try makeStore()
        defer { removeDatabase(file) }
        let match = Memory(title: "SQLite retrieval", content: "SQLite FTS5 BM25 ranks memory retrieval.")
        let other = Memory(title: "Garden", content: "Water the tomato plants daily.")
        try store.upsert(match)
        try store.upsert(other)

        let hits = try store.search("SQLite BM25 retrieval")
        XCTAssertEqual(hits.first?.memory.id, match.id)
        XCTAssertGreaterThan(hits.first?.score ?? 0, 0)

        // Stemming test: "water" query matches "Water" / "Watering"
        let stemHits = try store.search("water")
        XCTAssertEqual(stemHits.first?.memory.id, other.id)
    }

    func testContextNeverExceedsTokenBudget() throws {
        let (store, file) = try makeStore()
        defer { removeDatabase(file) }
        try store.upsert(Memory(title: "Rules", content: String(repeating: "relevant guidance ", count: 120)))
        let settings = ZeddySettings(budget: TokenBudget(totalTokens: 80, projectRatio: 0.5), minScore: 0)
        let block = try ContextBuilder.build(prompt: "relevant guidance", projectPath: nil, store: store, settings: settings)
        XCTAssertLessThanOrEqual(block.usedTokens, block.budgetTokens)
    }

    func testExportImportRoundTrip() throws {
        let (source, sourceFile) = try makeStore()
        let (destination, destinationFile) = try makeStore()
        defer { removeDatabase(sourceFile); removeDatabase(destinationFile) }
        let memory = Memory(title: "Exported", content: "This survives a JSON backup.", tags: ["backup"])
        try source.upsert(memory)
        XCTAssertEqual(try destination.importJSON(source.allJSON()), 1)
        let imported = try XCTUnwrap(destination.get(memory.id.uuidString))
        XCTAssertEqual(imported.id, memory.id)
        XCTAssertEqual(imported.title, memory.title)
        XCTAssertEqual(imported.content, memory.content)
        XCTAssertEqual(imported.tags, memory.tags)
    }

    func testIPCPayloadRoundTrip() throws {
        let frame = IPC.Frame.add(title: "Protocol", content: "Typed payloads reduce client mistakes.")
        let data = try IPC.encoder.encode(frame)
        let decoded = try IPC.decoder.decode(IPC.Frame.self, from: data)
        XCTAssertEqual(decoded.method, "add")
        XCTAssertEqual(decoded.params["title"]?.stringValue, "Protocol")
    }

    func testUsageTrackerAndThroughput() throws {
        let (store, file) = try makeStore()
        defer { removeDatabase(file) }
        let tracker = UsageTracker()
        let engine = Engine(store: store, usageTracker: tracker)

        // Seed a memory
        _ = engine.dispatch(IPC.Frame.add(title: "Architecture", content: "Fast local SQLite FTS5 store"))

        // Build context
        let ctxFrame = IPC.Frame.buildContext(prompt: "architecture sqlite")
        let res = engine.dispatch(ctxFrame)
        XCTAssertTrue(res.ok)

        // Query usage stats via IPC
        let statsRes = engine.dispatch(IPC.Frame.usageStats(period: "live"))
        XCTAssertTrue(statsRes.ok)
        guard let data = statsRes.data,
              let stats = try? IPC.decoder.decode(UsageStats.self, from: IPC.encoder.encode(data)) else {
            XCTFail("Could not decode UsageStats")
            return
        }

        XCTAssertEqual(stats.totalRequests, 2)
        XCTAssertGreaterThan(stats.totalInjectedTokens, 0)
        XCTAssertEqual(stats.liveBuckets.count, 15)

        // Query usage logs via IPC
        let logsRes = engine.dispatch(IPC.Frame.usageLogs(limit: 10))
        XCTAssertTrue(logsRes.ok)
        guard let logsData = logsRes.data,
              let logs = try? IPC.decoder.decode([UsageEvent].self, from: IPC.encoder.encode(logsData)) else {
            XCTFail("Could not decode logs")
            return
        }

        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs[0].method, "build_context")
        XCTAssertEqual(logs[1].method, "add")
    }
}
