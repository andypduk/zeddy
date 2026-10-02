import Foundation

/// The output of a single context-build: a compact, budget-capped block of
/// memory ready to be injected into a prompt, plus bookkeeping about what was
/// injected.
public struct ContextBlock: Codable, Sendable {
    public var text: String
    public var usedIds: [String]
    public var usedTokens: Int
    public var budgetTokens: Int

    public init(text: String, usedIds: [String], usedTokens: Int, budgetTokens: Int) {
        self.text = text
        self.usedIds = usedIds
        self.usedTokens = usedTokens
        self.budgetTokens = budgetTokens
    }
}

/// Turns the store + settings + a prompt into a lean injected-context block.
///
/// This is the token-savings engine. It:
///  1. Ranks memories by relevance (FTS bm25) to the current prompt.
///  2. Splits a hard token budget between project- and global-scoped memories.
///  3. Greedily packs the best memories under each budget.
///  4. Renders them in a tight markdown shape (minimal per-item overhead).
///
/// Over-estimating tokens (see `TokenEstimator`) means the block never
/// exceeds its budget — injecting *less* is always safe, more is not.
public enum ContextBuilder {

    public static func build(
        prompt: String,
        projectPath: String?,
        store: MemoryStore,
        settings: ZeddySettings
    ) throws -> ContextBlock {
        let budget = settings.budget
        let minScore = settings.minScore

        // Gather ranked candidates per scope. Project memories take priority in
        // the prompt, so we search both and let the budget decide the mix.
        let projectHits = try store.search(
            prompt, kind: .project, projectPath: projectPath, limit: 64
        ).filter { $0.score >= minScore }
        let globalHits = try store.search(
            prompt, kind: .global, limit: 64
        ).filter { $0.score >= minScore }

        let projectHeaderCost = TokenEstimator.estimate("## Project memory\n")
        let globalHeaderCost = TokenEstimator.estimate("## Global memory\n")
        var projectTokens = 0
        var globalTokens = 0
        var projectBlocks: [String] = []
        var globalBlocks: [String] = []
        var usedIds: [String] = []

        for hit in projectHits {
            let cost = renderCost(hit.memory)
            let prefix = projectBlocks.isEmpty ? projectHeaderCost : 0
            guard projectTokens + prefix + cost <= budget.projectTokens else { continue }
            projectTokens += prefix + cost
            projectBlocks.append(render(hit.memory))
            usedIds.append(hit.memory.id.uuidString)
        }
        for hit in globalHits {
            let cost = renderCost(hit.memory)
            let prefix = globalBlocks.isEmpty ? globalHeaderCost : 0
            guard globalTokens + prefix + cost <= budget.globalTokens else { continue }
            globalTokens += prefix + cost
            globalBlocks.append(render(hit.memory))
            usedIds.append(hit.memory.id.uuidString)
        }

        var text = ""
        var sections = 0
        if !projectBlocks.isEmpty {
            text += "## Project memory\n" + projectBlocks.joined(separator: "\n\n") + "\n"
            sections += 1
        }
        if !globalBlocks.isEmpty {
            text += "## Global memory\n" + globalBlocks.joined(separator: "\n\n") + "\n"
            sections += 1
        }

        if sections == 0 {
            return ContextBlock(
                text: "", usedIds: [], usedTokens: 0, budgetTokens: budget.totalTokens
            )
        }

        let usedTokens = TokenEstimator.estimate(text)
        // Record usage so the store can learn what matters (decays over time).
        try? store.markUsed(usedIds)

        return ContextBlock(
            text: text,
            usedIds: usedIds,
            usedTokens: usedTokens,
            budgetTokens: budget.totalTokens
        )
    }

    // MARK: - Rendering

    /// A tight, LLM-friendly rendering of one memory. Deliberately low-overhead:
    /// a short title line then the body, nothing else.
    private static func render(_ m: Memory) -> String {
        let scope = m.projectPath.map { "  (project: \($0))\n" } ?? ""
        return "### \(m.title)\n\(m.content)\n\(scope)"
    }

    private static func renderCost(_ m: Memory) -> Int {
        // Include every rendered character plus the blank separator between
        // entries. This is intentionally conservative.
        TokenEstimator.estimate(render(m)) + 2
    }
}
