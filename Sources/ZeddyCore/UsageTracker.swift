import Foundation

/// In-memory ring buffer & real-time throughput metrics tracker for Zeddy.
///
/// Models 9Router's usage dashboard KPIs:
/// - Total requests
/// - Injected / cached context tokens
/// - Estimated saved tokens (compression / token saver)
/// - Average latency (ms)
/// - Active throughput (req/s, tokens/s)
/// - Histogram timeline buckets
public final class UsageTracker: @unchecked Sendable {
    public static let shared = UsageTracker()

    private let lock = NSLock()
    private var events: [UsageEvent] = []
    private let capacity: Int = 300

    private var cumulativeRequests: Int = 0
    private var cumulativeInjectedTokens: Int = 0
    private var cumulativeSavedTokens: Int = 0
    private var cumulativeDurationMs: Double = 0.0

    public init() {}

    /// Record a processed Zeddy operation.
    @discardableResult
    public func record(
        method: String,
        promptSnippet: String,
        injectedTokens: Int = 0,
        budgetTokens: Int = 0,
        estimatedSavedTokens: Int = 0,
        durationMs: Double = 0.0,
        status: String = "success",
        memoryTitles: [String] = []
    ) -> UsageEvent {
        let event = UsageEvent(
            id: UUID().uuidString,
            timestamp: .now,
            method: method,
            promptSnippet: promptSnippet,
            injectedTokens: injectedTokens,
            budgetTokens: budgetTokens,
            estimatedSavedTokens: estimatedSavedTokens,
            durationMs: durationMs,
            status: status,
            memoryTitles: memoryTitles
        )

        lock.lock()
        defer { lock.unlock() }

        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }

        cumulativeRequests += 1
        cumulativeInjectedTokens += injectedTokens
        cumulativeSavedTokens += estimatedSavedTokens
        cumulativeDurationMs += durationMs

        return event
    }

    /// Retrieve aggregate statistics formatted for 9Router-style dashboard.
    public func stats(period: String = "live") -> UsageStats {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let cutoff: Date
        switch period.lowercased() {
        case "live":
            cutoff = now.addingTimeInterval(-60) // last 60 seconds
        case "today":
            cutoff = Calendar.current.startOfDay(for: now)
        default: // "all"
            cutoff = Date.distantPast
        }

        let filtered = events.filter { $0.timestamp >= cutoff }

        let reqCount = (period.lowercased() == "all") ? cumulativeRequests : filtered.count
        let injTokens = (period.lowercased() == "all") ? cumulativeInjectedTokens : filtered.reduce(0) { $0 + $1.injectedTokens }
        let savedTokens = (period.lowercased() == "all") ? cumulativeSavedTokens : filtered.reduce(0) { $0 + $1.estimatedSavedTokens }
        let totalMs = (period.lowercased() == "all") ? cumulativeDurationMs : filtered.reduce(0.0) { $0 + $1.durationMs }
        let avgLatency = reqCount > 0 ? (totalMs / Double(reqCount)) : 0.0

        // Active throughput in last 10 seconds
        let tenSecAgo = now.addingTimeInterval(-10)
        let last10s = events.filter { $0.timestamp >= tenSecAgo }
        let windowSec = 10.0
        let reqPerSec = Double(last10s.count) / windowSec
        let tokPerSec = Double(last10s.reduce(0) { $0 + $1.injectedTokens }) / windowSec

        // Build 15 discrete time buckets across last 60 seconds (4s per bucket)
        let bucketCount = 15
        let bucketDuration: TimeInterval = 4.0
        let chartStart = now.addingTimeInterval(-Double(bucketCount) * bucketDuration)

        var buckets: [ThroughputBucket] = []
        for i in 0..<bucketCount {
            let bStart = chartStart.addingTimeInterval(Double(i) * bucketDuration)
            let bEnd = bStart.addingTimeInterval(bucketDuration)
            let inBucket = events.filter { $0.timestamp >= bStart && $0.timestamp < bEnd }
            let bReqs = inBucket.count
            let bToks = inBucket.reduce(0) { $0 + $1.injectedTokens }
            buckets.append(ThroughputBucket(
                id: "\(i)",
                timestamp: bStart,
                requestCount: bReqs,
                tokenCount: bToks
            ))
        }

        return UsageStats(
            totalRequests: reqCount,
            totalInjectedTokens: injTokens,
            totalSavedTokens: savedTokens,
            averageLatencyMs: avgLatency,
            requestsPerSec: reqPerSec,
            tokensPerSec: tokPerSec,
            liveBuckets: buckets,
            period: period
        )
    }

    /// Retrieve recent request logs (newest first).
    public func recentLogs(limit: Int = 50) -> [UsageEvent] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(limit, events.count)
        return Array(events.suffix(count).reversed())
    }

    /// Reset all metrics.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
        cumulativeRequests = 0
        cumulativeInjectedTokens = 0
        cumulativeSavedTokens = 0
        cumulativeDurationMs = 0.0
    }
}
