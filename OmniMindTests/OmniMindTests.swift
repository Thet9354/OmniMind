//
//  OmniMindTests.swift
//  OmniMindTests
//
//  Phase 0 verification suite: the persistence foundation must boot
//  in-memory, round-trip models, honor cascade deletes, and preserve
//  embedding vectors byte-exact.
//

import Foundation
import SwiftData
import Testing
@testable import OmniMind

@Suite("Phase 0 — Persistence foundation")
struct PersistenceTests {

    /// Fresh, isolated in-memory stack per test. The container must outlive
    /// the context, so both are returned and held by the caller.
    private func makeStack() throws -> (container: ModelContainer, context: ModelContext) {
        let container = try ModelContainerFactory.make(inMemory: true)
        return (container, ModelContext(container))
    }

    @Test("ModelContainer boots fully in-memory")
    func containerBootsInMemory() throws {
        let stack = try makeStack()
        let allInMemory = stack.container.configurations.allSatisfy { $0.isStoredInMemoryOnly }
        #expect(allInMemory)
    }

    @Test("Meeting with segments round-trips through the store")
    func meetingRoundTrips() throws {
        let stack = try makeStack()
        let context = stack.context

        let meeting = Meeting(title: "Q3 Planning")
        context.insert(meeting)
        for i in 0..<5 {
            let segment = Segment(
                text: "Segment \(i)",
                startTime: Double(i) * 10,
                endTime: Double(i) * 10 + 8,
                confidence: 0.9
            )
            segment.meeting = meeting
            context.insert(segment)
        }
        try context.save()

        let fetchedMeetings = try context.fetch(FetchDescriptor<Meeting>())
        let fetchedSegments = try context.fetch(FetchDescriptor<Segment>())
        #expect(fetchedMeetings.count == 1)
        #expect(fetchedMeetings.first?.title == "Q3 Planning")
        #expect(fetchedMeetings.first?.segments.count == 5)
        #expect(fetchedSegments.count == 5)
    }

    @Test("Deleting a meeting cascade-deletes its segments")
    func cascadeDelete() throws {
        let stack = try makeStack()
        let context = stack.context

        let meeting = Meeting(title: "Doomed")
        context.insert(meeting)
        for i in 0..<3 {
            let segment = Segment(
                text: "Segment \(i)",
                startTime: 0,
                endTime: 1,
                confidence: 1.0
            )
            segment.meeting = meeting
            context.insert(segment)
        }
        try context.save()

        context.delete(meeting)
        try context.save()

        let remainingMeetings = try context.fetch(FetchDescriptor<Meeting>())
        let remainingSegments = try context.fetch(FetchDescriptor<Segment>())
        #expect(remainingMeetings.isEmpty)
        #expect(remainingSegments.isEmpty)
    }

    @Test("Embedding vector round-trips byte-exact")
    func vectorRoundTrips() throws {
        let stack = try makeStack()
        let context = stack.context

        let original = (0..<512).map { _ in Float.random(in: -1...1) }
        let data = original.withUnsafeBytes { Data($0) }

        let segment = Segment(
            text: "vectorized",
            startTime: 0,
            endTime: 2,
            confidence: 0.95,
            embeddingData: data,
            embeddingDimension: original.count
        )
        context.insert(segment)
        try context.save()

        let results = try context.fetch(FetchDescriptor<Segment>())
        let fetched = try #require(results.first)
        #expect(fetched.embeddingDimension == 512)
        #expect(fetched.vector == original)   // byte-exact, no tolerance
    }
}
