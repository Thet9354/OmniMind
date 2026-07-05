//
//  Embedder.swift
//  OmniMind
//
//  Sentence-vector generation on NLContextualEmbedding (transformer-based,
//  fully on-device). Vectors are mean-pooled over token embeddings and
//  L2-normalized at creation, so retrieval-time cosine similarity reduces
//  to a single vDSP dot product.
//

import Foundation
import NaturalLanguage

nonisolated enum EmbeddingError: Error, Equatable {
    /// No contextual embedding model exists for the language.
    case modelUnavailable
    /// Model exists but its assets could not be downloaded (§5.5).
    case assetsUnavailable
    case emptyText
    case embeddingFailed
}

/// Not Sendable by design: create one per owning actor (EmbeddingStore holds
/// its own) and never share across isolation domains.
nonisolated final class Embedder {
    let dimension: Int
    private let model: NLContextualEmbedding

    /// Creates a loaded, ready-to-embed instance, downloading the OS-managed
    /// model assets on first use. Callers treat failure as non-fatal:
    /// segments persist unembedded and are backfilled once assets arrive.
    static func prepare(language: NLLanguage = .english) async throws -> Embedder {
        guard let model = NLContextualEmbedding(language: language) else {
            throw EmbeddingError.modelUnavailable
        }
        if !model.hasAvailableAssets {
            let result: NLContextualEmbedding.AssetsResult
            do {
                result = try await model.requestAssets()
            } catch {
                throw EmbeddingError.assetsUnavailable
            }
            guard result == .available else {
                throw EmbeddingError.assetsUnavailable
            }
        }
        try model.load()
        return Embedder(model: model)
    }

    private init(model: NLContextualEmbedding) {
        self.model = model
        self.dimension = model.dimension
    }

    /// Mean-pooled, L2-normalized sentence vector for the text.
    func embed(_ text: String) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }

        let result = try model.embeddingResult(for: trimmed, language: nil)

        var pooled = [Double](repeating: 0, count: dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(
            in: trimmed.startIndex..<trimmed.endIndex
        ) { vector, _ in
            for i in 0..<min(vector.count, pooled.count) {
                pooled[i] += vector[i]
            }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0 else { throw EmbeddingError.embeddingFailed }

        var floats = pooled.map { Float($0 / Double(tokenCount)) }
        VectorMath.normalize(&floats)
        return floats
    }
}
