//
//  ExtractiveSummarizer.swift
//  OmniMind
//
//  Fallback summarization for hardware without Apple Intelligence: rank
//  segments by centroid similarity (the most "central" utterances carry
//  the meeting's theme), then emit the top K in chronological order.
//  Degrades further to a length heuristic when vectors are absent.
//  Never returns empty for non-empty input — the availability fallback
//  chain must terminate in something useful (§ Phase 6 gate).
//

import Foundation

nonisolated enum ExtractiveSummarizer {
    /// - Parameter entries: chronological (text, optional normalized vector).
    static func summarize(
        entries: [(text: String, vector: [Float]?)],
        maxSentences: Int = 3
    ) -> String {
        let usable = entries.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty, maxSentences > 0 else { return "" }

        let scores = centralityScores(for: usable)

        // Top K by score, then chronological so the summary reads forward.
        let topIndices = scores.indices
            .sorted { scores[$0] > scores[$1] }
            .prefix(maxSentences)
            .sorted()

        return topIndices.map { usable[$0].text }.joined(separator: " ")
    }

    private static func centralityScores(
        for entries: [(text: String, vector: [Float]?)]
    ) -> [Double] {
        // Uniform-dimension vectors only (defensive; one embedder in practice).
        let vectors = entries.compactMap(\.vector)
        guard let dimension = vectors.first?.count,
              vectors.count >= max(2, entries.count / 2),
              vectors.allSatisfy({ $0.count == dimension })
        else {
            // Length heuristic: longer utterances carry more content.
            return entries.map { Double($0.text.count) }
        }

        var centroid = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            for i in 0..<dimension { centroid[i] += vector[i] }
        }
        VectorMath.normalize(&centroid)

        return entries.map { entry in
            guard let vector = entry.vector, vector.count == dimension else {
                return -1   // unembedded segments rank last, never crash
            }
            return Double(VectorMath.dot(centroid, vector))
        }
    }
}
