//
//  CoalescerTests.swift
//  OmniMindTests
//
//  Phase 7.5 verification suite: segment coalescing rules, pilot-mode
//  access, locale rejection, and cleanup degradation.
//

import Foundation
import Testing
@testable import OmniMind

@Suite("Phase 7.5 — Segment coalescing")
struct SegmentCoalescerTests {

    private func segment(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double = 0.8
    ) -> TranscriptSegment {
        TranscriptSegment(text: text, startTime: start, endTime: end, confidence: confidence)
    }

    @Test("Micro-utterances accumulate until the word threshold, then flush as one chunk")
    func wordThresholdFlush() {
        var coalescer = SegmentCoalescer(
            configuration: .init(minWords: 10, maxDuration: 60, gapThreshold: 5)
        )
        // 3 + 3 + 2 words: below threshold, nothing flushes.
        #expect(coalescer.ingest(segment("So Pac-Man moves.", start: 0, end: 2)).isEmpty)
        #expect(coalescer.ingest(segment("And it does.", start: 2.5, end: 4)).isEmpty)
        #expect(coalescer.ingest(segment("Yeah, right.", start: 4.5, end: 5)).isEmpty)
        #expect(coalescer.pendingText == "So Pac-Man moves. And it does. Yeah, right.")

        // Crossing 10 words flushes one merged chunk.
        let flushed = coalescer.ingest(segment("You can tap to move.", start: 5.5, end: 8))
        #expect(flushed.count == 1)
        let chunk = flushed[0]
        #expect(chunk.text == "So Pac-Man moves. And it does. Yeah, right. You can tap to move.")
        #expect(chunk.startTime == 0)
        #expect(chunk.endTime == 8)
        #expect(!coalescer.hasPending)
    }

    @Test("A silence gap closes the pending chunk before the new utterance")
    func gapFlush() {
        var coalescer = SegmentCoalescer(
            configuration: .init(minWords: 100, maxDuration: 600, gapThreshold: 2)
        )
        #expect(coalescer.ingest(segment("Before the pause.", start: 0, end: 3)).isEmpty)

        // 5-second silence — topic boundary.
        let flushed = coalescer.ingest(segment("After the pause.", start: 8, end: 10))
        #expect(flushed.count == 1)
        #expect(flushed[0].text == "Before the pause.")
        #expect(coalescer.pendingText == "After the pause.")
    }

    @Test("Duration cap bounds chunk length even for slow, sparse speech")
    func durationFlush() {
        var coalescer = SegmentCoalescer(
            configuration: .init(minWords: 1_000, maxDuration: 15, gapThreshold: 60)
        )
        #expect(coalescer.ingest(segment("One.", start: 0, end: 6)).isEmpty)
        #expect(coalescer.ingest(segment("Two.", start: 7, end: 12)).isEmpty)
        let flushed = coalescer.ingest(segment("Three.", start: 13, end: 16))
        #expect(flushed.count == 1)
        #expect(flushed[0].endTime == 16)
    }

    @Test("flush() emits the remainder at stream end; confidence is averaged")
    func remainderFlush() {
        var coalescer = SegmentCoalescer()
        _ = coalescer.ingest(segment("Closing remark.", start: 0, end: 2, confidence: 1.0))
        _ = coalescer.ingest(segment("Goodbye.", start: 2, end: 3, confidence: 0.5))

        let remainder = coalescer.flush()
        #expect(remainder?.text == "Closing remark. Goodbye.")
        #expect(remainder.map { abs($0.confidence - 0.75) < 1e-9 } == true)
        #expect(coalescer.flush() == nil)   // nothing left
    }

    @Test("Empty coalescer flushes nothing")
    func emptyFlush() {
        var coalescer = SegmentCoalescer()
        #expect(coalescer.flush() == nil)
        #expect(!coalescer.hasPending)
        #expect(coalescer.pendingText.isEmpty)
    }
}

@Suite("Phase 7.5 — Pilot access & quality plumbing")
struct PilotModeTests {

    @Test("Pilot mode grants full access regardless of entitlement tier")
    @MainActor
    func pilotGrantsFullAccess() async {
        let store = EntitlementStore()
        await store.refreshEntitlements()
        #expect(store.activeTier == .free)          // no purchase exists
        #expect(store.hasFullAccess)                // …but everything is open
        #expect(ProductCatalog.pilotUnlockEverything)
    }

    @Test("Unsupported transcription locale fails fast with a typed error")
    func bogusLocaleRejected() async {
        await #expect(throws: TranscriptionError.localeUnsupported("xx_XX")) {
            _ = try await TranscriptionActor(locale: Locale(identifier: "xx_XX"))
        }
    }

    @Test("Transcript cleanup degrades to nil (raw transcript stands) without the model")
    func cleanupDegradesToNil() async {
        let synthesizer = MeetingSynthesizer(forceExtractive: true)
        let result = await synthesizer.cleanTranscript([
            TranscriptSegment(text: "acces the metal of the object", startTime: 0, endTime: 3, confidence: 0.5)
        ])
        #expect(result == nil)
    }

    @Test("Cleanup of an empty meeting is nil, never a hallucinated document")
    func cleanupEmptyIsNil() async {
        let result = await MeetingSynthesizer().cleanTranscript([])
        #expect(result == nil)
    }
}
