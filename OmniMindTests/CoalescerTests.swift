//
//  CoalescerTests.swift
//  OmniMindTests
//
//  Phase 7.5 verification suite: segment coalescing rules, pilot-mode
//  access, locale rejection, and cleanup degradation.
//

import Foundation
import SwiftData
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

    @Test("Auto-title sanitizer: quotes, punctuation, and length are tamed")
    func titleSanitizer() {
        #expect(MeetingSynthesizer.sanitizedTitle(from: "\"Q3 Budget Review\"")
                == "Q3 Budget Review")
        #expect(MeetingSynthesizer.sanitizedTitle(from: "Pac-Man Coding Lesson.")
                == "Pac-Man Coding Lesson")
        #expect(MeetingSynthesizer.sanitizedTitle(
            from: "Here is the title:\nSprint Planning Sync\nHope that helps!"
        ) == "Sprint Planning Sync")
        // Hard cap at eight words.
        let rambling = MeetingSynthesizer.sanitizedTitle(
            from: "A very long meandering title that keeps going on and on forever"
        )
        #expect(rambling?.split(separator: " ").count == 8)
        // Garbage in → nil, keep the date title.
        #expect(MeetingSynthesizer.sanitizedTitle(from: "  \"\" ") == nil)
    }

    @Test("Auto-title and action items degrade to nil without the model")
    func titleAndActionsDegrade() async {
        let synthesizer = MeetingSynthesizer(forceExtractive: true)
        let segments = [
            TranscriptSegment(
                text: "John will send the budget forecast by Friday.",
                startTime: 0, endTime: 4, confidence: 0.9
            )
        ]
        #expect(await synthesizer.title(for: segments) == nil)
        #expect(await synthesizer.actionItems(from: segments) == nil)
    }

    @Test("renameMeeting replaces the title; blank titles are ignored")
    func renameMeeting() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let id = try await store.createMeeting(title: "Capture 5 Jul 2026")

        try await store.renameMeeting(id, title: "Pilot Kickoff")
        try await store.renameMeeting(id, title: "   ")   // ignored

        let context = ModelContext(container)
        let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        #expect(meeting.title == "Pilot Kickoff")
    }

    @Test("LLM preamble chatter is stripped; substantive text is untouched")
    func preambleStripped() {
        // The exact leak observed in on-device testing (2026-07-05).
        let leaked = """
        I apologize for the mistake. Here is the repaired transcript:

        Is saying I have 13 mistakes. Line 31, brackets expected.
        So we say Eve? Teacher? Oh, it's 15.
        """
        let stripped = MeetingSynthesizer.strippingPreamble(from: leaked)
        #expect(stripped.hasPrefix("Is saying I have 13 mistakes."))
        #expect(stripped.contains("So we say Eve?"))

        // A clean reply passes through byte-identical.
        let clean = "The meeting covered the budget.\nAction items follow."
        #expect(MeetingSynthesizer.strippingPreamble(from: clean) == clean)

        // "Here is..." only counts as preamble when it reads like one —
        // a transcript that genuinely STARTS with those words survives.
        let legit = "Here is the plan we agreed on for Q3 and why it matters."
        #expect(MeetingSynthesizer.strippingPreamble(from: legit) == legit)
    }
}
