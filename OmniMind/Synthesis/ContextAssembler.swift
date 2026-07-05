//
//  ContextAssembler.swift
//  OmniMind
//
//  Deterministic RAG context construction: retrieval hits in, one grounded
//  prompt block out — never exceeding the token budget. Token counts use
//  the ~4 chars/token heuristic, which over-counts for English (safe
//  direction: budgets are ceilings, not targets).
//

import Foundation

nonisolated struct AssembledContext: Sendable, Equatable {
    /// Hits that made it under the budget, in score order.
    let hits: [SearchHit]
    /// The formatted grounding block for the prompt.
    let text: String
    let estimatedTokens: Int

    static let empty = AssembledContext(hits: [], text: "", estimatedTokens: 0)
}

nonisolated enum ContextAssembler {
    /// ~4 characters per token; rounds up so budgets stay conservative.
    static func estimateTokens(_ text: String) -> Int {
        (text.count + 3) / 4
    }

    /// Packs score-ordered hits until the budget is exhausted. Oversized
    /// hits are skipped (not truncated) so every included excerpt remains
    /// verbatim — a grounding block must never contain fabricated partial
    /// sentences.
    static func assemble(hits: [SearchHit], tokenBudget: Int = 1_200) -> AssembledContext {
        guard tokenBudget > 0 else { return .empty }
        var included: [SearchHit] = []
        var blocks: [String] = []
        var total = 0
        for hit in hits {
            let block = "[\(hit.meetingTitle) @ \(timestamp(hit.startTime))] \(hit.text)"
            let cost = estimateTokens(block)
            guard total + cost <= tokenBudget else { continue }
            included.append(hit)
            blocks.append(block)
            total += cost
        }
        return AssembledContext(
            hits: included,
            text: blocks.joined(separator: "\n"),
            estimatedTokens: total
        )
    }

    /// Hard-clips free text to a token budget (whole-transcript summaries).
    static func clip(_ text: String, toTokens budget: Int) -> String {
        let maxCharacters = budget * 4
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
