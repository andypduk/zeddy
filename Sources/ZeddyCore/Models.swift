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

// MARK: - Usage & Throughput Tracking Models (9Router Style)

public struct UsageEvent: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var timestamp: Date
    public var method: String
    public var promptSnippet: String
    public var injectedTokens: Int
    public var budgetTokens: Int
    public var estimatedSavedTokens: Int
    public var durationMs: Double
    public var status: String
    public var memoryTitles: [String]

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = .now,
        method: String,
        promptSnippet: String,
        injectedTokens: Int = 0,
        budgetTokens: Int = 0,
        estimatedSavedTokens: Int = 0,
        durationMs: Double = 0.0,
        status: String = "success",
        memoryTitles: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.promptSnippet = promptSnippet
        self.injectedTokens = injectedTokens
        self.budgetTokens = budgetTokens
        self.estimatedSavedTokens = estimatedSavedTokens
        self.durationMs = durationMs
        self.status = status
        self.memoryTitles = memoryTitles
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, method, promptSnippet, injectedTokens, budgetTokens, estimatedSavedTokens, durationMs, status, memoryTitles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let epoch = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: epoch)
        method = try container.decode(String.self, forKey: .method)
        promptSnippet = try container.decode(String.self, forKey: .promptSnippet)
        injectedTokens = try container.decodeIfPresent(Int.self, forKey: .injectedTokens) ?? 0
        budgetTokens = try container.decodeIfPresent(Int.self, forKey: .budgetTokens) ?? 0
        estimatedSavedTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedSavedTokens) ?? 0
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs) ?? 0.0
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "success"
        memoryTitles = try container.decodeIfPresent([String].self, forKey: .memoryTitles) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try container.encode(method, forKey: .method)
        try container.encode(promptSnippet, forKey: .promptSnippet)
        try container.encode(injectedTokens, forKey: .injectedTokens)
        try container.encode(budgetTokens, forKey: .budgetTokens)
        try container.encode(estimatedSavedTokens, forKey: .estimatedSavedTokens)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(status, forKey: .status)
        try container.encode(memoryTitles, forKey: .memoryTitles)
    }
}

public struct ThroughputBucket: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var timestamp: Date
    public var requestCount: Int
    public var tokenCount: Int

    public init(id: String = UUID().uuidString, timestamp: Date = .now, requestCount: Int, tokenCount: Int) {
        self.id = id
        self.timestamp = timestamp
        self.requestCount = requestCount
        self.tokenCount = tokenCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, requestCount, tokenCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let epoch = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: epoch)
        requestCount = try container.decode(Int.self, forKey: .requestCount)
        tokenCount = try container.decode(Int.self, forKey: .tokenCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try container.encode(requestCount, forKey: .requestCount)
        try container.encode(tokenCount, forKey: .tokenCount)
    }
}

public struct UsageStats: Codable, Sendable, Hashable {
    public var totalRequests: Int
    public var totalInjectedTokens: Int
    public var totalSavedTokens: Int
    public var averageLatencyMs: Double
    public var requestsPerSec: Double
    public var tokensPerSec: Double
    public var liveBuckets: [ThroughputBucket]
    public var period: String
    public var allTimeRequests: Int
    public var allTimeInjectedTokens: Int
    public var allTimeSavedTokens: Int

    public init(
        totalRequests: Int = 0,
        totalInjectedTokens: Int = 0,
        totalSavedTokens: Int = 0,
        averageLatencyMs: Double = 0.0,
        requestsPerSec: Double = 0.0,
        tokensPerSec: Double = 0.0,
        liveBuckets: [ThroughputBucket] = [],
        period: String = "live",
        allTimeRequests: Int = 0,
        allTimeInjectedTokens: Int = 0,
        allTimeSavedTokens: Int = 0
    ) {
        self.totalRequests = totalRequests
        self.totalInjectedTokens = totalInjectedTokens
        self.totalSavedTokens = totalSavedTokens
        self.averageLatencyMs = averageLatencyMs
        self.requestsPerSec = requestsPerSec
        self.tokensPerSec = tokensPerSec
        self.liveBuckets = liveBuckets
        self.period = period
        self.allTimeRequests = allTimeRequests
        self.allTimeInjectedTokens = allTimeInjectedTokens
        self.allTimeSavedTokens = allTimeSavedTokens
    }
}
