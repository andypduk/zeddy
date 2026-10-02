import Foundation

/// Rough token estimation without shipping a real tokenizer.
///
/// LLM tokenizers (cl100k / o200k) typically produce **0.5–1.3 tokens per
/// whitespace token** and about **3.5–4 characters per token** for English-ish
/// code/mixed text. We deliberately over-estimate slightly so a "budget" of N
/// tokens stays conservative — injecting *less* than the budget is always safe,
/// injecting *more* is not.
public enum TokenEstimator {
    /// Average characters per token for mixed prose/code. Slightly low on
    /// purpose so we over-count tokens.
    public static let charsPerToken = 3.7

    /// Roughly how many whitespace-delimited tokens each LLM token covers.
    public static let whitespaceTokensPerToken = 1.1

    /// Estimate the token count of `text`.
    public static func estimate(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        let charBased = Double(text.utf8.count) / charsPerToken
        let ws = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        let wsBased = Double(ws.count) / whitespaceTokensPerToken
        // Max of the two heuristics = conservative upper bound.
        return Int((max(charBased, wsBased)).rounded(.up)) + 1
    }

    /// Estimate cost of a block of rendered memory (title + body).
    public static func estimateRendered(title: String, body: String) -> Int {
        // A little overhead per block for markdown markers / separators.
        estimate(title) + estimate(body) + 3
    }
}
