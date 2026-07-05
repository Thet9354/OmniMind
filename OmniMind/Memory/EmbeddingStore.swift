//
//  EmbeddingStore.swift
//  OmniMind
//
//  The single persistence funnel. Every write to the store crosses this
//  actor; ModelContext is not Sendable, and @ModelActor gives it a private
//  serial executor (invariant #3 of the design spec). All public APIs accept
//  and return Sendable DTOs — live @Model objects never cross the boundary.
//
//  Embedding generation attaches here in Phase 4: persist() will embed the
//  segment text before insert, keeping vector writes atomic with row writes.
//

import Foundation
import SwiftData

nonisolated enum PersistenceError: Error, Equatable {
    case meetingNotFound(UUID)
}

@ModelActor
actor EmbeddingStore {

    // MARK: - Meetings

    func createMeeting(title: String, startedAt: Date = .now) throws -> UUID {
        let meeting = Meeting(title: title, startedAt: startedAt)
        modelContext.insert(meeting)
        try modelContext.save()
        return meeting.id
    }

    func endMeeting(_ id: UUID, at date: Date = .now) throws {
        guard let meeting = try fetchMeeting(id) else {
            throw PersistenceError.meetingNotFound(id)
        }
        meeting.endedAt = date
        try modelContext.save()
    }

    func deleteMeeting(_ id: UUID) throws {
        guard let meeting = try fetchMeeting(id) else {
            throw PersistenceError.meetingNotFound(id)
        }
        modelContext.delete(meeting)   // cascade removes segments + vectors
        try modelContext.save()
    }

    // MARK: - Segments

    /// Persists one finalized segment. Saves immediately: each finalized
    /// utterance is durable the moment it exists, so a crash mid-meeting
    /// loses at most the in-flight volatile hypothesis.
    func persist(_ segment: TranscriptSegment, into meetingID: UUID) throws {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        insert(segment, into: meeting)
        try modelContext.save()
    }

    /// Batch variant: one save for the whole array. For imports and tests —
    /// the live capture path wants per-utterance durability instead.
    func persist(_ segments: [TranscriptSegment], into meetingID: UUID) throws {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        for segment in segments {
            insert(segment, into: meeting)
        }
        try modelContext.save()
    }

    /// Segments of a meeting as DTOs, ordered by start time.
    func segments(in meetingID: UUID) throws -> [TranscriptSegment] {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        return meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map { model in
                TranscriptSegment(
                    id: model.id,
                    text: model.text,
                    startTime: model.startTime,
                    endTime: model.endTime,
                    confidence: model.confidence,
                    capturedAt: model.capturedAt
                )
            }
    }

    // MARK: - Private

    private func insert(_ segment: TranscriptSegment, into meeting: Meeting) {
        let model = Segment(
            id: segment.id,
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime,
            confidence: segment.confidence,
            capturedAt: segment.capturedAt
        )
        model.meeting = meeting
        modelContext.insert(model)
    }

    private func fetchMeeting(_ id: UUID) throws -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
