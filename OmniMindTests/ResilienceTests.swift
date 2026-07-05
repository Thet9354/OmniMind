//
//  ResilienceTests.swift
//  OmniMindTests
//
//  Phase 7 verification suite: the §5.1 memory bound as a structural
//  property, windowed pagination, and export rendering. The Instruments
//  Allocations pass on a real device complements these — here we prove
//  the bounds by construction.
//

import Foundation
import SwiftData
import Testing
@testable import OmniMind

@Suite("Phase 7 — Live-transcript memory bound")
struct TailBufferTests {

    @Test("A 3-hour session leaves exactly `capacity` elements resident")
    func threeHourSessionStaysBounded() {
        // 3 hours at one finalized utterance every ~5 s ≈ 2160 finals.
        var tail = TailBuffer<Int>(capacity: 50)
        for i in 0..<2_160 {
            tail.append(i)
        }
        #expect(tail.elements.count == 50)
        #expect(tail.totalAppended == 2_160)
        #expect(tail.evictedCount == 2_110)
        // The window is the NEWEST 50, in arrival order.
        #expect(tail.elements == Array(2_110..<2_160))
    }

    @Test("Under capacity nothing is evicted; removeAll resets the session")
    func underCapacityAndReset() {
        var tail = TailBuffer<String>(capacity: 50)
        tail.append("a")
        tail.append("b")
        #expect(tail.elements == ["a", "b"])
        #expect(tail.evictedCount == 0)

        tail.removeAll()
        #expect(tail.elements.isEmpty)
        #expect(tail.totalAppended == 0)
    }
}

@Suite("Phase 7 — Windowed pagination")
struct SegmentPagerTests {

    @Test("500 segments page as 200/200/100 — ordered, disjoint, complete")
    func pagesAreWindowsOfTheWhole() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let meetingID = try await store.createMeeting(title: "Marathon")
        let batch = (0..<500).map { i in
            TranscriptSegment(
                text: "Segment \(i)",
                startTime: Double(i) * 5,
                endTime: Double(i) * 5 + 4,
                confidence: 0.9
            )
        }
        try await store.persist(batch, into: meetingID)

        let context = ModelContext(container)
        let page1 = try SegmentPager.page(in: context, meetingID: meetingID, offset: 0)
        let page2 = try SegmentPager.page(in: context, meetingID: meetingID, offset: 200)
        let page3 = try SegmentPager.page(in: context, meetingID: meetingID, offset: 400)
        let beyond = try SegmentPager.page(in: context, meetingID: meetingID, offset: 500)

        #expect(page1.count == 200)
        #expect(page2.count == 200)
        #expect(page3.count == 100)
        #expect(beyond.isEmpty)

        // Ordered within and ACROSS pages, no overlap, full coverage.
        let all = page1 + page2 + page3
        let starts = all.map(\.startTime)
        #expect(starts == starts.sorted())
        #expect(Set(all.map(\.id)).count == 500)
    }

    @Test("Paging is scoped to the requested meeting only")
    func pagingIsMeetingScoped() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let target = try await store.createMeeting(title: "Target")
        let other = try await store.createMeeting(title: "Other")
        try await store.persist(
            [TranscriptSegment(text: "mine", startTime: 0, endTime: 1, confidence: 1)],
            into: target
        )
        try await store.persist(
            [TranscriptSegment(text: "not mine", startTime: 0, endTime: 1, confidence: 1)],
            into: other
        )

        let context = ModelContext(container)
        let page = try SegmentPager.page(in: context, meetingID: target, offset: 0)
        #expect(page.map(\.text) == ["mine"])
    }
}

@Suite("Phase 7 — Transcript export")
struct TranscriptExporterTests {

    @Test("Markdown carries title, time range, ordered timestamped segments")
    func markdownComplete() {
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let markdown = TranscriptExporter.markdown(
            title: "Q3 Planning",
            startedAt: started,
            endedAt: started.addingTimeInterval(3_600),
            segments: [
                (startTime: 0, text: "Kickoff and agenda."),
                (startTime: 65, text: "Budget review."),
                (startTime: 3_540, text: "Wrap-up and actions."),
            ]
        )

        #expect(markdown.hasPrefix("# Q3 Planning"))
        #expect(markdown.contains("**[00:00]** Kickoff and agenda."))
        #expect(markdown.contains("**[01:05]** Budget review."))
        #expect(markdown.contains("**[59:00]** Wrap-up and actions."))
        // Chronological order in the document.
        let kickoff = markdown.range(of: "Kickoff")!
        let wrap = markdown.range(of: "Wrap-up")!
        #expect(kickoff.lowerBound < wrap.lowerBound)
        #expect(markdown.contains("Transcribed on-device"))
    }

    @Test("Open-ended meeting (no endedAt) still renders a valid header")
    func openEndedMeeting() {
        let markdown = TranscriptExporter.markdown(
            title: "Live",
            startedAt: .now,
            endedAt: nil,
            segments: []
        )
        #expect(markdown.hasPrefix("# Live"))
        #expect(!markdown.contains("– "))   // no dangling end-time separator
    }
}
