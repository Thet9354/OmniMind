//
//  EmbeddingStoreTests.swift
//  OmniMindTests
//
//  Phase 3 verification suite: the @ModelActor persistence funnel. DTOs in,
//  DTOs out, cascade deletes, per-utterance durability, and 1k-segment
//  scale with a hard latency ceiling.
//

import Foundation
import SwiftData
import Testing
@testable import OmniMind

@Suite("Phase 3 — EmbeddingStore persistence funnel")
struct EmbeddingStoreTests {

    private func makeStore() throws -> (container: ModelContainer, store: EmbeddingStore) {
        let container = try ModelContainerFactory.make(inMemory: true)
        return (container, EmbeddingStore(modelContainer: container))
    }

    private func segment(_ i: Int, text: String? = nil) -> TranscriptSegment {
        TranscriptSegment(
            text: text ?? "Segment number \(i)",
            startTime: Double(i) * 5,
            endTime: Double(i) * 5 + 4,
            confidence: 0.9
        )
    }

    @Test("Segments round-trip as DTOs, ordered by start time")
    func dtoRoundTripOrdered() async throws {
        let (container, store) = try makeStore()
        _ = container

        let meetingID = try await store.createMeeting(title: "Standup")
        // Persist deliberately out of order.
        for i in [3, 0, 2, 1] {
            try await store.persist(segment(i), into: meetingID)
        }

        let fetched = try await store.segments(in: meetingID)
        #expect(fetched.count == 4)
        #expect(fetched.map(\.startTime) == [0, 5, 10, 15])
        #expect(fetched[1].text == "Segment number 1")
    }

    @Test("Persisting into an unknown meeting throws meetingNotFound")
    func unknownMeetingThrows() async throws {
        let (container, store) = try makeStore()
        _ = container

        let ghost = UUID()
        await #expect(throws: PersistenceError.meetingNotFound(ghost)) {
            try await store.persist(segment(0), into: ghost)
        }
    }

    @Test("deleteMeeting cascades to segments through the store")
    func deleteCascades() async throws {
        let (container, store) = try makeStore()

        let meetingID = try await store.createMeeting(title: "Doomed")
        try await store.persist((0..<5).map { segment($0) }, into: meetingID)
        try await store.deleteMeeting(meetingID)

        // Verify via an independent context on the same container.
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Segment>()) == 0)
    }

    @Test("endMeeting stamps endedAt")
    func endMeetingStamps() async throws {
        let (container, store) = try makeStore()

        let meetingID = try await store.createMeeting(title: "Retro")
        let end = Date(timeIntervalSinceNow: 60)
        try await store.endMeeting(meetingID, at: end)

        let context = ModelContext(container)
        let meeting = try #require(
            try context.fetch(FetchDescriptor<Meeting>()).first
        )
        let endedAt = try #require(meeting.endedAt)
        #expect(abs(endedAt.timeIntervalSince(end)) < 1)
    }

    @Test("1k segments persist, count exactly, and read back under a latency ceiling")
    func thousandSegmentScale() async throws {
        let (container, store) = try makeStore()

        let meetingID = try await store.createMeeting(title: "All Hands")
        let batch = (0..<1_000).map { segment($0) }

        let clock = ContinuousClock()
        let writeDuration = try await clock.measure {
            try await store.persist(batch, into: meetingID)
        }

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Segment>()) == 1_000)

        var readBack: [TranscriptSegment] = []
        let readDuration = try await clock.measure {
            readBack = try await store.segments(in: meetingID)
        }
        #expect(readBack.count == 1_000)
        #expect(readBack.first?.startTime == 0)
        #expect(readBack.last?.startTime == 4_995)

        // Generous ceilings — these catch algorithmic regressions
        // (per-row saves in the batch path, O(n²) ordering), not CI jitter.
        #expect(writeDuration < .seconds(10), "batch write took \(writeDuration)")
        #expect(readDuration < .seconds(5), "read-back took \(readDuration)")
    }
}
