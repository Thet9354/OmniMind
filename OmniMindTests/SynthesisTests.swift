//
//  SynthesisTests.swift
//  OmniMindTests
//
//  Phase 6 verification suite. Context assembly and the extractive
//  fallback are pure and run everywhere; the Foundation Models branch is
//  availability-gated (Apple Intelligence hardware only).
//

import Foundation
import FoundationModels
import Testing
@testable import OmniMind

@Suite("Phase 6 — Context assembly")
struct ContextAssemblerTests {

    private func hit(_ text: String, score: Float = 0.9) -> SearchHit {
        SearchHit(
            id: UUID(), meetingID: UUID(), meetingTitle: "Sync",
            text: text, startTime: 30, capturedAt: .now, score: score
        )
    }

    @Test("Assembled context never exceeds the token budget")
    func budgetIsCeiling() {
        // 60 hits × ~50 tokens each ≈ 3000 tokens offered against a 500 budget.
        let hits = (0..<60).map { i in
            hit(String(repeating: "budget words here ", count: 11) + "#\(i)")
        }
        let context = ContextAssembler.assemble(hits: hits, tokenBudget: 500)

        #expect(context.estimatedTokens <= 500)
        #expect(!context.hits.isEmpty)
        #expect(context.hits.count < hits.count)   // budget actually bit
        // Direct recount from the final text agrees with the running total.
        #expect(ContextAssembler.estimateTokens(context.text)
                <= 500 + context.hits.count)       // + newline slack
    }

    @Test("Hits are included in score order; formatting carries provenance")
    func scoreOrderAndProvenance() {
        let hits = [hit("first by score", score: 0.9), hit("second by score", score: 0.5)]
        let context = ContextAssembler.assemble(hits: hits, tokenBudget: 1_000)
        #expect(context.hits.map(\.text) == ["first by score", "second by score"])
        #expect(context.text.contains("[Sync @ 00:30] first by score"))
    }

    @Test("Oversized hits are skipped verbatim, never truncated")
    func oversizedSkipped() {
        let giant = hit(String(repeating: "x", count: 8_000))   // ~2000 tokens
        let small = hit("fits fine", score: 0.1)
        let context = ContextAssembler.assemble(hits: [giant, small], tokenBudget: 100)
        #expect(context.hits.map(\.text) == ["fits fine"])
    }

    @Test("Empty input and zero budget yield the empty context")
    func emptyEdges() {
        #expect(ContextAssembler.assemble(hits: [], tokenBudget: 500) == .empty)
        #expect(ContextAssembler.assemble(hits: [hit("a")], tokenBudget: 0) == .empty)
    }

    @Test("clip enforces the character-derived ceiling")
    func clipCeiling() {
        let long = String(repeating: "a", count: 10_000)
        let clipped = ContextAssembler.clip(long, toTokens: 100)
        #expect(clipped.count == 400)
        #expect(ContextAssembler.clip("short", toTokens: 100) == "short")
    }
}

@Suite("Phase 6 — Extractive fallback")
struct ExtractiveSummarizerTests {

    /// Unit vector along one axis of a 8-dim space.
    private func axis(_ i: Int, dim: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[i] = 1
        return v
    }

    @Test("Centroid ranking surfaces the dominant topic, in chronological order")
    func centroidPicksTheme() throws {
        // Three "budget" segments share an axis; one outlier sits elsewhere.
        var near = axis(0)
        near[1] = 0.3
        VectorMath.normalize(&near)

        let entries: [(text: String, vector: [Float]?)] = [
            ("Budget kickoff discussion.", axis(0)),
            ("Totally unrelated cat story.", axis(5)),
            ("Budget numbers were reviewed.", near),
            ("Budget deadline confirmed for Friday.", axis(0)),
        ]
        let summary = ExtractiveSummarizer.summarize(entries: entries, maxSentences: 3)

        #expect(!summary.contains("cat story"))
        // Chronological: kickoff before numbers before deadline.
        let kickoff = try #require(summary.range(of: "kickoff"))
        let deadline = try #require(summary.range(of: "deadline"))
        #expect(kickoff.lowerBound < deadline.lowerBound)
    }

    @Test("No vectors: falls back to length heuristic, still non-empty")
    func lengthFallback() {
        let entries: [(text: String, vector: [Float]?)] = [
            ("Yes.", nil),
            ("We agreed to ship the release candidate on Thursday after QA signs off.", nil),
            ("Ok.", nil),
        ]
        let summary = ExtractiveSummarizer.summarize(entries: entries, maxSentences: 1)
        #expect(summary.contains("release candidate"))
    }

    @Test("Empty and whitespace-only input yields empty; non-empty never does")
    func emptinessContract() {
        #expect(ExtractiveSummarizer.summarize(entries: []) == "")
        #expect(ExtractiveSummarizer.summarize(entries: [("   ", nil)]) == "")
        #expect(ExtractiveSummarizer.summarize(entries: [("One real sentence.", nil)])
                == "One real sentence.")
    }

    @Test("maxSentences bounds the output")
    func sentenceCap() {
        let entries = (0..<10).map { ("Sentence number \($0).", Optional(axis(0))) }
        let summary = ExtractiveSummarizer.summarize(
            entries: entries.map { (text: $0.0, vector: $0.1) },
            maxSentences: 2
        )
        #expect(summary.components(separatedBy: "Sentence").count - 1 == 2)
    }
}

@Suite("Phase 6 — Synthesis orchestration")
struct MeetingSynthesizerTests {

    private func embedded(_ text: String, vector: [Float]?) -> EmbeddedSegment {
        EmbeddedSegment(
            segment: TranscriptSegment(
                text: text, startTime: 0, endTime: 5, confidence: 0.9
            ),
            vector: vector
        )
    }

    @Test("Unavailable-model branch produces a non-empty extractive summary")
    func fallbackBranchNonEmpty() async {
        let synthesizer = MeetingSynthesizer(forceExtractive: true)
        let output = await synthesizer.summarize([
            embedded("We decided to move the launch to March.", vector: nil),
            embedded("Marketing will prepare the announcement next week.", vector: nil),
        ])
        #expect(output.method == .extractive)
        #expect(!output.text.isEmpty)
        #expect(output.text.contains("launch") || output.text.contains("announcement"))
    }

    @Test("Empty meeting summarizes to empty without crashing")
    func emptyMeeting() async {
        let output = await MeetingSynthesizer(forceExtractive: true).summarize([])
        #expect(output.text.isEmpty)
    }

    @Test("Q&A returns nil when the model is unavailable — hits-only UI")
    func answerNilWithoutModel() async {
        let synthesizer = MeetingSynthesizer(forceExtractive: true)
        let context = ContextAssembler.assemble(hits: [
            SearchHit(id: UUID(), meetingID: UUID(), meetingTitle: "Sync",
                      text: "The budget is due Friday.", startTime: 0,
                      capturedAt: .now, score: 0.9)
        ])
        let answer = await synthesizer.answer(question: "When is the budget due?", context: context)
        #expect(answer == nil)
    }

    /// Availability alone is not truthful on simulators: the flag can read
    /// .available while actual inference is sandbox-denied. Gate on a real
    /// probe generation succeeding.
    static func foundationModelResponds() async -> Bool {
        guard SystemLanguageModel.default.availability == .available else {
            return false
        }
        let session = LanguageModelSession()
        return (try? await session.respond(to: "Reply with the word OK.")) != nil
    }

    @Test(
        "Foundation model summary generates non-empty on-device text",
        .enabled("requires working Apple Intelligence inference") {
            await MeetingSynthesizerTests.foundationModelResponds()
        },
        .timeLimit(.minutes(5))
    )
    func foundationModelSummary() async {
        let output = await MeetingSynthesizer().summarize([
            embedded("We decided to move the product launch from January to March because the hardware certification is delayed.", vector: nil),
            embedded("Marketing will prepare the revised announcement plan by next Friday.", vector: nil),
            embedded("Engineering confirmed the firmware is feature-complete.", vector: nil),
        ])
        #expect(output.method == .foundationModel)
        #expect(!output.text.isEmpty)
    }
}
