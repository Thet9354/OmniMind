//
//  EmbeddingSearchTests.swift
//  OmniMindTests
//
//  Phase 4 verification suite. Pure-math and throughput gates run
//  everywhere; semantic-quality gates require the on-device
//  NLContextualEmbedding assets and skip where they can't be installed.
//

import Foundation
import SwiftData
import Testing
@testable import OmniMind

@Suite("Phase 4 — Vector math & top-K")
struct VectorMathTests {

    @Test("Normalized vector has unit self-similarity")
    func selfSimilarityIsOne() {
        var v = (0..<512).map { _ in Float.random(in: -1...1) }
        VectorMath.normalize(&v)
        #expect(abs(VectorMath.dot(v, v) - 1.0) < 1e-5)
    }

    @Test("Normalize is a no-op on the zero vector")
    func zeroVectorSafe() {
        var zero = [Float](repeating: 0, count: 64)
        VectorMath.normalize(&zero)
        #expect(zero.allSatisfy { $0 == 0 })
    }

    @Test("Orthogonal vectors score 0, opposite vectors score -1")
    func cosineExtremes() {
        var x: [Float] = [1, 0]
        var y: [Float] = [0, 1]
        var negX: [Float] = [-1, 0]
        VectorMath.normalize(&x)
        VectorMath.normalize(&y)
        VectorMath.normalize(&negX)
        #expect(abs(VectorMath.dot(x, y)) < 1e-6)
        #expect(abs(VectorMath.dot(x, negX) + 1) < 1e-6)
    }

    @Test("TopKHeap keeps exactly the K best, ordered")
    func topKKeepsBest() {
        var heap = TopKHeap<Int>(k: 5)
        // Insert 0...99 shuffled; best five are 95...99.
        for value in (0..<100).shuffled() {
            heap.insert(value, score: Float(value))
        }
        let result = heap.sortedDescending()
        #expect(result.map(\.element) == [99, 98, 97, 96, 95])
    }

    @Test("TopKHeap with k=0 stays empty; fewer inserts than k all survive")
    func topKEdges() {
        var empty = TopKHeap<Int>(k: 0)
        empty.insert(1, score: 1)
        #expect(empty.sortedDescending().isEmpty)

        var small = TopKHeap<Int>(k: 10)
        small.insert(1, score: 1)
        small.insert(2, score: 2)
        #expect(small.sortedDescending().map(\.element) == [2, 1])
    }

    @Test("50k-vector scan with top-K completes under 50 ms")
    func fiftyThousandVectorScan() {
        let dimension = 512
        let count = 50_000
        var query = (0..<dimension).map { _ in Float.random(in: -1...1) }
        VectorMath.normalize(&query)

        // Flat corpus of normalized vectors (the hot-path input shape;
        // SwiftData row I/O is measured separately in Phase 3's scale test).
        var corpus: [[Float]] = []
        corpus.reserveCapacity(count)
        for _ in 0..<count {
            var v = (0..<dimension).map { _ in Float.random(in: -1...1) }
            VectorMath.normalize(&v)
            corpus.append(v)
        }

        let clock = ContinuousClock()
        var heap = TopKHeap<Int>(k: 8)
        let duration = clock.measure {
            for (index, vector) in corpus.enumerated() {
                heap.insert(index, score: VectorMath.dot(query, vector))
            }
        }

        #expect(heap.sortedDescending().count == 8)
        #expect(duration < .milliseconds(50), "50k scan took \(duration)")
    }
}

@Suite("Phase 4 — Semantic search (asset-gated)")
struct SemanticSearchTests {

    /// True when the contextual-embedding assets are present/installable.
    static func embedderReady() async -> Bool {
        (try? await Embedder.prepare()) != nil
    }

    private func makeStore() throws -> (container: ModelContainer, store: EmbeddingStore) {
        let container = try ModelContainerFactory.make(inMemory: true)
        return (container, EmbeddingStore(modelContainer: container))
    }

    @Test(
        "Embedded sentence has ~unit self-similarity and stored dimension",
        .enabled("requires on-device NLContextualEmbedding assets") {
            await SemanticSearchTests.embedderReady()
        },
        .timeLimit(.minutes(5))
    )
    func realEmbeddingSelfSimilarity() async throws {
        let embedder = try await Embedder.prepare()
        let vector = try embedder.embed("The quarterly budget review is on Monday.")
        #expect(vector.count == embedder.dimension)
        #expect(abs(VectorMath.dot(vector, vector) - 1.0) < 1e-4)
    }

    @Test(
        "Query 'budget deadline' ranks the finance segment above distractors",
        .enabled("requires on-device NLContextualEmbedding assets") {
            await SemanticSearchTests.embedderReady()
        },
        .timeLimit(.minutes(5))
    )
    func relevanceRanking() async throws {
        let (container, store) = try makeStore()
        _ = container
        try await store.prepareEmbedder()

        let meetingID = try await store.createMeeting(title: "Weekly Sync")
        let finance = TranscriptSegment(
            text: "Finance needs the budget report before the deadline on Friday.",
            startTime: 0, endTime: 5, confidence: 0.9
        )
        let cat = TranscriptSegment(
            text: "The cat chased the laser pointer around the living room.",
            startTime: 5, endTime: 10, confidence: 0.9
        )
        let kitchen = TranscriptSegment(
            text: "We should repaint the office kitchen a warmer color.",
            startTime: 10, endTime: 15, confidence: 0.9
        )
        try await store.persist([finance, cat, kitchen], into: meetingID)

        let hits = try await store.search("budget deadline", topK: 3)
        #expect(hits.count == 3)
        #expect(hits.first?.id == finance.id, "top hit was: \(hits.first?.text ?? "none")")
        #expect((hits.first?.score ?? 0) > (hits.last?.score ?? 0))
    }

    @Test(
        "Segments persisted without assets are repaired by backfill and become searchable",
        .enabled("requires on-device NLContextualEmbedding assets") {
            await SemanticSearchTests.embedderReady()
        },
        .timeLimit(.minutes(5))
    )
    func backfillRepairsUnembedded() async throws {
        let (container, store) = try makeStore()

        // Persist BEFORE preparing the embedder — simulates capture while
        // assets were missing (§5.5).
        let meetingID = try await store.createMeeting(title: "Offline Capture")
        let segment = TranscriptSegment(
            text: "Ship the release candidate to TestFlight tomorrow.",
            startTime: 0, endTime: 4, confidence: 0.9
        )
        try await store.persist(segment, into: meetingID)

        let context = ModelContext(container)
        let raw = try #require(try context.fetch(FetchDescriptor<Segment>()).first)
        #expect(raw.embeddingDimension == 0)   // proved unembedded

        try await store.prepareEmbedder()
        let repaired = try await store.backfillEmbeddings()
        #expect(repaired == 1)

        let hits = try await store.search("TestFlight release", topK: 1)
        #expect(hits.first?.id == segment.id)
    }
}
