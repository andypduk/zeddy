import Foundation

// MARK: - Search

/// A relevance-ranked search hit. `score` is positive and higher-is-better
/// (derived from SQLite FTS5 `bm25`, which is negative).
public struct SearchHit: Codable, Sendable, Identifiable {
    public var memory: Memory
    public var score: Double
    public var id: UUID { memory.id }

    public init(memory: Memory, score: Double) {
        self.memory = memory
        self.score = score
    }
}

/// Payload for the `search` method.
public struct SearchPayload: Codable, Sendable {
    public var query: String
    public var projectPath: String?
    public var kind: MemoryKind?
    public var limit: Int

    public init(query: String, projectPath: String? = nil, kind: MemoryKind? = nil, limit: Int = 8) {
        self.query = query
        self.projectPath = projectPath
        self.kind = kind
        self.limit = limit
    }
}

// MARK: - List

/// Payload for the `list` method. All filters optional (empty = no filter).
public struct ListPayload: Codable, Sendable {
    public var kind: MemoryKind?
    public var projectPath: String?
    public var tag: String?

    public init(kind: MemoryKind? = nil, projectPath: String? = nil, tag: String? = nil) {
        self.kind = kind
        self.projectPath = projectPath
        self.tag = tag
    }
}

// MARK: - Build context

/// Payload for the `build_context` method. The optional `max*` fields override
/// the stored settings for this one call (used by `zeddy context --max-tokens`).
public struct BuildContextPayload: Codable, Sendable {
    public var prompt: String
    public var projectPath: String?
    public var maxMemories: Int?
    public var maxTokens: Int?
    public var topMemoryTokens: Int?

    public init(prompt: String, projectPath: String? = nil,
                maxMemories: Int? = nil, maxTokens: Int? = nil, topMemoryTokens: Int? = nil) {
        self.prompt = prompt
        self.projectPath = projectPath
        self.maxMemories = maxMemories
        self.maxTokens = maxTokens
        self.topMemoryTokens = topMemoryTokens
    }
}

/// Result of `build_context`: the rendered block plus accounting for the UI.
public struct BuildContextResult: Codable, Sendable {
    public var context: String
    public var selectedCount: Int
    public var estimatedTokens: Int
    public var truncated: Bool

    public init(context: String, selectedCount: Int, estimatedTokens: Int, truncated: Bool) {
        self.context = context
        self.selectedCount = selectedCount
        self.estimatedTokens = estimatedTokens
        self.truncated = truncated
    }
}

// MARK: - Prune

/// Payload for the `prune` method: drop memories unused for longer than `days`.
public struct PrunePayload: Codable, Sendable {
    public var days: Int

    public init(days: Int) {
        self.days = days
    }
}

// MARK: - Row

/// The row shape returned by `list` (a `Memory` without its `content`, which
/// the list view does not need). Kept lean so listing is cheap. The daemon's
/// `list` serializes full `Memory` values; both clients decode the subset they
/// need into this shape (or their own view-model type of the same fields).
public struct ListRow: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: MemoryKind
    public var title: String
    public var projectPath: String?
    public var tags: [String]
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(id: String, kind: MemoryKind, title: String, projectPath: String? = nil,
                tags: [String] = [], createdAt: Date, lastUsedAt: Date? = nil, useCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.projectPath = projectPath
        self.tags = tags
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        let kindRaw = try c.decode(String.self, forKey: .kind)
        self.kind = MemoryKind(rawValue: kindRaw) ?? .note
        self.title = try c.decode(String.self, forKey: .title)
        self.projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        let createdAt = try c.decode(Double.self, forKey: .createdAt)
        self.createdAt = Date(timeIntervalSince1970: createdAt)
        if let lu = try c.decodeIfPresent(Double.self, forKey: .lastUsedAt) {
            self.lastUsedAt = Date(timeIntervalSince1970: lu)
        } else {
            self.lastUsedAt = nil
        }
        self.useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(title, forKey: .title)
        if let projectPath { try c.encode(projectPath, forKey: .projectPath) }
        try c.encode(tags, forKey: .tags)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        if let lastUsedAt { try c.encode(lastUsedAt.timeIntervalSince1970, forKey: .lastUsedAt) }
        try c.encode(useCount, forKey: .useCount)
    }
}
