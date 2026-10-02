import Foundation

/// Persistent memory store backed by SQLite + FTS5.
///
/// Layout:
///  - `memories`    — the source of truth (regular table, keeps a `rowid`).
///  - `memories_fts`— an FTS5 *external-content* index over `memories` (`content='memories'`,
///                     `content_rowid='rowid'`). It stores only the index, so the real
///                     text stays in `memories` and we avoid double storage.
///
/// Retrieval is `MATCH` + `bm25(...)`, which gives us relevance ranking for free.
/// The whole public surface is guarded by a single lock so the daemon and GUI can
/// share one store file safely.
public final class MemoryStore: @unchecked Sendable {
    private let db: SQLite.Connection
    private let lock = NSLock()

    public static let schemaVersion = 1

    /// The on-disk path of the database file (used by status displays / the GUI).
    public let databasePath: String

    /// The underlying SQLite library version (for status displays / the GUI).
    public var libraryVersion: String { db.libraryVersion }

    public init(path: String) throws {
        let conn = try SQLite.Connection(path: path)
        self.db = conn
        self.databasePath = path
        lock.lock()
        defer { lock.unlock() }
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS memories (
                id           TEXT UNIQUE NOT NULL,
                kind         TEXT NOT NULL,
                title        TEXT NOT NULL,
                content      TEXT NOT NULL,
                project_path TEXT,
                tags         TEXT NOT NULL DEFAULT '[]',
                created_at   REAL NOT NULL,
                last_used_at REAL,
                use_count    INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_memories_kind    ON memories(kind);
            CREATE INDEX IF NOT EXISTS idx_memories_project ON memories(project_path);

            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
            USING fts5(title, content, content='memories', content_rowid='rowid', tokenize='porter unicode61');

            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            """
        )
        let v = meta("schema_version") ?? "0"
        if v != String(Self.schemaVersion) {
            metaSet("schema_version", String(Self.schemaVersion))
            // A version bump would go here. Keep the FTS index consistent.
            try db.exec("INSERT INTO memories_fts(memories_fts) VALUES('rebuild');")
        }
    }

    // MARK: - CRUD

    public func upsert(_ memory: Memory) throws {
        lock.lock()
        defer { lock.unlock() }
        let tagsJSON = encodeTags(memory.tags)
        let id = memory.id.uuidString
        if let existing = try findById(id), let oldRowid = try rowid(for: id) {
            // Update path: replace the source row, then re-index the FTS entry.
            _ = try db.run(
                """
                UPDATE memories SET kind=?1, title=?2, content=?3, project_path=?4, tags=?5,
                                    created_at=?6, last_used_at=?7, use_count=?8
                WHERE id=?9
                """,
                [memory.kind.rawValue, memory.title, memory.content, memory.projectPath, tagsJSON,
                 memory.createdAt, memory.lastUsedAt, memory.useCount, id]
            )
            try syncFTSDelete(rowid: oldRowid, memory: existing)
            try syncFTSInsert(rowid: oldRowid, memory: memory)
        } else {
            _ = try db.run(
                """
                INSERT INTO memories (id, kind, title, content, project_path, tags, created_at, last_used_at, use_count)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                """,
                [id, memory.kind.rawValue, memory.title, memory.content,
                 memory.projectPath, tagsJSON, memory.createdAt, memory.lastUsedAt, memory.useCount]
            )
            let rowid = try lastInsertRowid()
            try syncFTSInsert(rowid: rowid, memory: memory)
        }
    }

    public func get(_ id: String) throws -> Memory? {
        lock.lock(); defer { lock.unlock() }
        return try findById(id)
    }

    public func delete(_ id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let m = try findById(id), let rowid = try rowid(for: id) else { return false }
        try syncFTSDelete(rowid: rowid, memory: m)
        _ = try db.run("DELETE FROM memories WHERE id = ?1", [id])
        return true
    }

    public func list(kind: Memory.Kind? = nil, projectPath: String? = nil, tag: String? = nil) throws -> [Memory] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT id, kind, title, content, project_path, tags, created_at, last_used_at, use_count, rowid FROM memories WHERE 1=1"
        var params: [Any?] = []
        if let kind { params.append(kind.rawValue); sql += " AND kind = ?\(params.count)" }
        if let projectPath { params.append(projectPath); sql += " AND project_path = ?\(params.count)" }
        if let tag { params.append("%\"" + tag + "\"%"); sql += " AND tags LIKE ?\(params.count)" }
        sql += " ORDER BY created_at DESC"
        var out: [Memory] = []
        try db.query(sql, params) { row in
            if let m = memory(from: row) { out.append(m) }
        }
        return out
    }

    public func count() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var out = 0
        try db.query("SELECT COUNT(*) FROM memories", []) { out = $0.int(0) }
        return out
    }

    // MARK: - Search (FTS5 + bm25)

    /// Retrieve the most relevant memories for `query`, ranked by BM25.
    /// Returns at most `limit` hits, optionally filtered by scope.
    public func search(_ query: String, kind: Memory.Kind? = nil, projectPath: String? = nil, limit: Int = 8) throws -> [SearchHit] {
        lock.lock(); defer { lock.unlock() }
        let fts = ftsQuery(from: query)
        guard !fts.isEmpty else { return [] }
        var sql = """
            SELECT m.id, m.kind, m.title, m.content, m.project_path, m.tags, m.created_at, m.last_used_at, m.use_count, bm25(memories_fts)
            FROM memories_fts
            JOIN memories m ON m.rowid = memories_fts.rowid
            WHERE memories_fts MATCH ?1
            """
        var params: [Any?] = [fts]
        if let kind { params.append(kind.rawValue); sql += " AND m.kind = ?\(params.count)" }
        if let projectPath { params.append(projectPath); sql += " AND m.project_path = ?\(params.count)" }
        sql += " ORDER BY bm25(memories_fts) LIMIT \(max(1, limit))"
        var hits: [SearchHit] = []
        try db.query(sql, params) { row in
            if let m = memory(from: row) {
                // FTS5's bm25() is negative (more negative = more relevant).
                // Flip it so a positive, higher-is-better score flows upward;
                // ContextBuilder then filters `score > minScore` correctly.
                hits.append(SearchHit(memory: m, score: -row.double(9)))
            }
        }
        return hits
    }

    // MARK: - Usage bookkeeping

    /// Bump usage stats for a set of memory ids (called when they are injected).
    public func markUsed(_ ids: [String], at date: Date = .now) throws {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            _ = try db.run(
                """
                UPDATE memories SET use_count = use_count + 1, last_used_at = ?1 WHERE id = ?2
                """, [date, id]
            )
        }
    }

    // MARK: - Stats

    public struct Stats: Codable, Sendable {
        public var total: Int
        public var byKind: [String: Int]
        public var byProject: [String: Int]
        public var newestCreatedAt: Date?
    }

    /// A snapshot of the store for status surfaces (CLI, GUI daemon pane).
    public struct StoreStatus: Codable, Sendable {
        public var total: Int
        public var byKind: [String: Int]
        public var byProject: [String: Int]
        public var latestCreatedAt: Double?
        public var databasePath: String
        public var libraryVersion: String

        public init(total: Int, byKind: [String: Int], byProject: [String: Int],
                    latestCreatedAt: Double?, databasePath: String, libraryVersion: String) {
            self.total = total
            self.byKind = byKind
            self.byProject = byProject
            self.latestCreatedAt = latestCreatedAt
            self.databasePath = databasePath
            self.libraryVersion = libraryVersion
        }
    }

    public func status() throws -> StoreStatus {
        let s = try stats()
        return StoreStatus(
            total: s.total,
            byKind: s.byKind,
            byProject: s.byProject,
            latestCreatedAt: s.newestCreatedAt?.timeIntervalSince1970,
            databasePath: databasePath,
            libraryVersion: libraryVersion
        )
    }

    public func stats() throws -> Stats {
        lock.lock(); defer { lock.unlock() }
        var byKind: [String: Int] = [:]
        var byProject: [String: Int] = [:]
        var total = 0
        var newest: Date?
        try db.query(
            "SELECT kind, project_path, created_at FROM memories", []
        ) { row in
            total += 1
            let k = row.string(0) ?? "global"
            byKind[k, default: 0] += 1
            if let p = row.string(1) { byProject[p, default: 0] += 1 }
            let ts = row.double(2)
            let d = Date(timeIntervalSince1970: ts)
            if newest == nil || d > newest! { newest = d }
        }
        return Stats(total: total, byKind: byKind, byProject: byProject, newestCreatedAt: newest)
    }

    // MARK: - Import / export

    public func all() throws -> [Memory] { try list() }

    public func allJSON() throws -> Data {
        // Memory encodes its dates as epoch doubles itself, so a plain encoder
        // round-trips faithfully (no date strategy needed).
        return try JSONEncoder().encode(try all())
    }

    public func importJSON(_ data: Data) throws -> Int {
        let items = try JSONDecoder().decode([Memory].self, from: data)
        for item in items { try upsert(item) }
        return items.count
    }

    /// Drop memories unused for longer than `olderThanDays`. Returns count removed.
    public func pruneUnused(olderThanDays: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date(timeIntervalSinceNow: -Double(olderThanDays) * 86_400)
        // Delete while holding this lock rather than calling the public `delete`
        // method, which would attempt to acquire the same non-recursive lock.
        let ids = try idsWhere(
            "SELECT id FROM memories WHERE use_count = 0 AND created_at < ?1",
            [cutoff]
        )
        for id in ids {
            guard let memory = try findById(id), let rowid = try rowid(for: id) else { continue }
            try syncFTSDelete(rowid: rowid, memory: memory)
            _ = try db.run("DELETE FROM memories WHERE id = ?1", [id])
        }
        return ids.count
    }

    // MARK: - meta helpers

    private func meta(_ key: String) -> String? {
        var out: String?
        _ = try? db.query("SELECT value FROM meta WHERE key = ?1", [key]) { row in out = row.string(0) }
        return out
    }

    private func metaSet(_ key: String, _ value: String) {
        _ = try? db.run("INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    // MARK: - Row mapping + FTS sync

    private func findById(_ id: String) throws -> Memory? {
        var out: Memory?
        try db.query(
            """
            SELECT id, kind, title, content, project_path, tags, created_at, last_used_at, use_count, rowid
            FROM memories WHERE id = ?1
            """, [id]
        ) { row in out = memory(from: row) }
        return out
    }

    private func rowid(for id: String) throws -> Int64? {
        var out: Int64?
        try db.query("SELECT rowid FROM memories WHERE id = ?1", [id]) { row in out = row.int64(0) }
        return out
    }

    private func lastInsertRowid() throws -> Int64 {
        var out: Int64 = 0
        try db.query("SELECT last_insert_rowid()", []) { row in out = row.int64(0) }
        return out
    }

    private func idsWhere(_ sql: String, _ params: [Any?]) throws -> [String] {
        var ids: [String] = []
        try db.query(sql, params) { row in if let s = row.string(0) { ids.append(s) } }
        return ids
    }

    // Column order for the source row (must match every SELECT that feeds this):
    //   0 id, 1 kind, 2 title, 3 content, 4 project_path, 5 tags,
    //   6 created_at, 7 last_used_at, 8 use_count, 9 rowid
    private func memory(from row: SQLite.Row) -> Memory? {
        guard let id = row.string(0) else { return nil }
        let kind = Memory.Kind(rawValue: row.string(1) ?? "global") ?? .global
        let title = row.string(2) ?? ""
        let content = row.string(3) ?? ""
        let projectPath = row.string(4)
        let tags = decodeTags(row.string(5))
        let createdAt = Date(timeIntervalSince1970: row.double(6))
        let lastUsed = (row[7] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Memory(
            id: UUID(uuidString: id) ?? UUID(),
            kind: kind,
            title: title,
            content: content,
            projectPath: (projectPath?.isEmpty == false) ? projectPath : nil,
            tags: tags,
            createdAt: createdAt,
            lastUsedAt: lastUsed,
            useCount: row.int(8)
        )
    }

    private func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tags),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private func decodeTags(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private func syncFTSInsert(rowid: Int64, memory: Memory) throws {
        try db.run(
            "INSERT INTO memories_fts(rowid, title, content) VALUES (?1, ?2, ?3)",
            [rowid, memory.title, memory.content]
        )
    }

    /// Remove a row's text from the FTS index. Needs the *old* indexed text,
    /// which the caller passes in (it is the current value, before mutation).
    private func syncFTSDelete(rowid: Int64, memory: Memory) throws {
        try db.run(
            """
            INSERT INTO memories_fts(memories_fts, rowid, title, content)
            VALUES ('delete', ?1, ?2, ?3)
            """,
            [rowid, memory.title, memory.content]
        )
    }

    private func syncFTSDelete(rowid: Int64) throws {
        guard let mem = try findByIdForRowid(rowid) else { return }
        try syncFTSDelete(rowid: rowid, memory: mem)
    }

    private func findByIdForRowid(_ rowid: Int64) throws -> Memory? {
        var out: Memory?
        try db.query(
            """
            SELECT id, kind, title, content, project_path, tags, created_at, last_used_at, use_count, rowid
            FROM memories WHERE rowid = ?1
            """, [rowid]
        ) { row in out = memory(from: row) }
        return out
    }

    /// Convert a free-text user query into a safe FTS5 expression.
    ///
    /// Strategy: treat each word as a phrase, joining with OR so a memory
    /// matches if *any* word is present (recall-friendly), then let bm25 rank
    /// it. This avoids the usual FTS "must match every term" surprise while
    /// still giving relevance ordering.
    private func ftsQuery(from query: String) -> String {
        let words = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        // Deduplicate while preserving order.
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        let phrases = unique.map { word -> String in
            let escaped = word.replacingOccurrences(of: "\"", with: "")
            return "\"" + escaped + "\""
        }
        return phrases.joined(separator: " OR ")
    }
}
