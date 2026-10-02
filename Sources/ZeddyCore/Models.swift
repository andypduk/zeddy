import Foundation

public struct Memory: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case global
        case project
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var content: String
    public var projectPath: String?
    public var tags: [String]
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(
        id: UUID = UUID(), kind: Kind = .global, title: String, content: String,
        projectPath: String? = nil, tags: [String] = [], createdAt: Date = .now,
        lastUsedAt: Date? = nil, useCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.projectPath = projectPath
        self.tags = tags
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    private enum CodingKeys: String, CodingKey { case id, kind, title, content, projectPath, tags, createdAt, lastUsedAt, useCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt))
        lastUsedAt = try container.decodeIfPresent(Double.self, forKey: .lastUsedAt).map(Date.init(timeIntervalSince1970:))
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(projectPath, forKey: .projectPath)
        try container.encode(tags, forKey: .tags)
        try container.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt?.timeIntervalSince1970, forKey: .lastUsedAt)
        try container.encode(useCount, forKey: .useCount)
    }
}

public struct SearchHit: Codable, Sendable, Identifiable {
    public var memory: Memory
    /// Positive relevance: larger scores are more relevant.
    public var score: Double
    public var id: UUID { memory.id }

    public init(memory: Memory, score: Double) {
        self.memory = memory
        self.score = score
    }
}

public struct TokenBudget: Codable, Sendable, Hashable {
    public var totalTokens: Int
    public var projectRatio: Double

    public init(totalTokens: Int = 1_200, projectRatio: Double = 0.65) {
        self.totalTokens = max(0, totalTokens)
        self.projectRatio = min(1, max(0, projectRatio))
    }

    public var projectTokens: Int { Int((Double(totalTokens) * projectRatio).rounded(.down)) }
    public var globalTokens: Int { totalTokens - projectTokens }
}

public struct ZeddySettings: Codable, Sendable, Hashable {
    public var budget: TokenBudget
    public var indexRefreshInterval: Double
    public var minScore: Double

    public init(budget: TokenBudget = TokenBudget(), indexRefreshInterval: Double = 5, minScore: Double = 0) {
        self.budget = budget
        self.indexRefreshInterval = max(0, indexRefreshInterval)
        self.minScore = minScore
    }

    public static let `default` = ZeddySettings()
}
