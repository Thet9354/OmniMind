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
    /// Bundle import found the meeting already in the library (IDs are
    /// preserved across devices exactly so re-imports are detectable).
    case meetingAlreadyExists(UUID)
}

@ModelActor
actor EmbeddingStore {
    /// Created by prepareEmbedder(). While nil, segments persist unembedded
    /// (dimension 0) and are picked up by backfillEmbeddings() later — asset
    /// unavailability must never block transcript durability (§5.5).
    private var embedder: Embedder?

    // MARK: - Embedder lifecycle

    /// Idempotent. Downloads the contextual-embedding assets on first call;
    /// failure leaves the store fully functional for persistence.
    func prepareEmbedder() async throws {
        guard embedder == nil else { return }
        embedder = try await Embedder.prepare()
    }

    var isEmbedderReady: Bool { embedder != nil }

    /// Embeds any segments persisted while the embedder was unavailable.
    /// Returns the number of segments backfilled.
    @discardableResult
    func backfillEmbeddings() throws -> Int {
        guard let embedder else { return 0 }
        let missing = try modelContext.fetch(
            FetchDescriptor<Segment>(predicate: #Predicate { $0.embeddingDimension == 0 })
        )
        var updated = 0
        for segment in missing {
            guard let vector = try? embedder.embed(segment.text) else { continue }
            segment.embeddingData = vector.withUnsafeBytes { Data($0) }
            segment.embeddingDimension = vector.count
            updated += 1
        }
        if updated > 0 {
            try modelContext.save()
        }
        return updated
    }

    // MARK: - Search (local RAG retrieval)

    /// Brute-force cosine scan over the whole corpus with a bounded top-K
    /// heap. O(n·d) SIMD work — sub-millisecond for tens of thousands of
    /// segments (see the 50k perf gate). An ANN index is deliberately NOT
    /// built at this scale.
    func search(_ query: String, topK: Int = 8) throws -> [SearchHit] {
        guard let embedder else { throw EmbeddingError.assetsUnavailable }
        let queryVector = try embedder.embed(query)

        let segments = try modelContext.fetch(FetchDescriptor<Segment>())
        var heap = TopKHeap<SearchHit>(k: topK)
        for segment in segments where segment.embeddingDimension == queryVector.count {
            let score = VectorMath.dot(queryVector, segment.vector)
            let hit = SearchHit(
                id: segment.id,
                meetingID: segment.meeting?.id ?? UUID(),
                meetingTitle: segment.meeting?.title ?? "Untitled",
                text: segment.text,
                startTime: segment.startTime,
                capturedAt: segment.capturedAt,
                score: score
            )
            heap.insert(hit, score: score)
        }
        return heap.sortedDescending().map(\.element)
    }

    // MARK: - Meetings

    /// - Parameter id: caller-supplied so session-scoped artifacts created
    ///   before the meeting row exists (the audio archive) share its identity.
    func createMeeting(id: UUID = UUID(), title: String, startedAt: Date = .now) throws -> UUID {
        let meeting = Meeting(id: id, title: title, startedAt: startedAt)
        modelContext.insert(meeting)
        try modelContext.save()
        return meeting.id
    }

    /// Auto-titling replaces the timestamp filename with meaning once the
    /// meeting closes; a failed rename keeps the date-based title.
    func renameMeeting(_ id: UUID, title: String) throws {
        guard let meeting = try fetchMeeting(id) else {
            throw PersistenceError.meetingNotFound(id)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meeting.title = trimmed
        try modelContext.save()
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
        AudioArchive.delete(for: id)   // retained audio goes with the meeting
    }

    // MARK: - Persisted AI outputs

    /// Sendable snapshot of a meeting's persisted synthesis artifacts.
    /// `actionItems` distinguishes nil (never extracted) from empty
    /// (extraction ran, no commitments found).
    struct SynthesisArtifacts: Sendable, Equatable {
        var summaryText: String?
        var summaryMethod: String?
        var cleanedTranscript: String?
        var actionItems: [ExtractedActionItem]?
    }

    func synthesisArtifacts(for meetingID: UUID) throws -> SynthesisArtifacts {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        return SynthesisArtifacts(
            summaryText: meeting.summaryText,
            summaryMethod: meeting.summaryMethod,
            cleanedTranscript: meeting.cleanedTranscript,
            actionItems: meeting.actionItemsData.flatMap {
                try? JSONDecoder().decode([ExtractedActionItem].self, from: $0)
            }
        )
    }

    func saveSummary(_ text: String, method: String, for meetingID: UUID) throws {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        meeting.summaryText = text
        meeting.summaryMethod = method
        try modelContext.save()
    }

    func saveCleanedTranscript(_ text: String, for meetingID: UUID) throws {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        meeting.cleanedTranscript = text
        try modelContext.save()
    }

    /// Persists the full array (extraction results AND check-off state —
    /// callers re-save on every toggle).
    func saveActionItems(_ items: [ExtractedActionItem], for meetingID: UUID) throws {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        meeting.actionItemsData = try JSONEncoder().encode(items)
        try modelContext.save()
    }

    // MARK: - Meeting bundles (serverless sharing)

    /// Everything a portable bundle carries, as one Sendable DTO. Vectors
    /// are intentionally omitted — the importing device re-embeds via
    /// backfillEmbeddings().
    func exportBundle(for meetingID: UUID) throws -> MeetingBundle {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        return MeetingBundle(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            summaryText: meeting.summaryText,
            summaryMethod: meeting.summaryMethod,
            cleanedTranscript: meeting.cleanedTranscript,
            actionItems: meeting.actionItemsData.flatMap {
                try? JSONDecoder().decode([ExtractedActionItem].self, from: $0)
            },
            segments: meeting.segments
                .sorted { $0.startTime < $1.startTime }
                .map {
                    MeetingBundle.BundleSegment(
                        id: $0.id,
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        confidence: $0.confidence,
                        capturedAt: $0.capturedAt
                    )
                }
        )
    }

    /// Recreates a received meeting, IDs preserved, in one atomic save.
    /// Segments embed immediately when the embedder is ready and degrade
    /// to unembedded rows otherwise — the same §5.5 contract as capture.
    func importMeeting(_ bundle: MeetingBundle) throws -> UUID {
        guard try fetchMeeting(bundle.id) == nil else {
            throw PersistenceError.meetingAlreadyExists(bundle.id)
        }
        let meeting = Meeting(
            id: bundle.id, title: bundle.title, startedAt: bundle.startedAt
        )
        meeting.endedAt = bundle.endedAt
        meeting.summaryText = bundle.summaryText
        meeting.summaryMethod = bundle.summaryMethod
        meeting.cleanedTranscript = bundle.cleanedTranscript
        meeting.actionItemsData = try bundle.actionItems.map(JSONEncoder().encode)
        modelContext.insert(meeting)
        for segment in bundle.segments {
            insert(
                TranscriptSegment(
                    id: segment.id,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    confidence: segment.confidence,
                    capturedAt: segment.capturedAt
                ),
                into: meeting
            )
        }
        try modelContext.save()
        return meeting.id
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

    /// Segments plus their stored vectors, for synthesis (summaries rank
    /// by centroid similarity). Vector is nil for unembedded segments.
    func embeddedSegments(in meetingID: UUID) throws -> [EmbeddedSegment] {
        guard let meeting = try fetchMeeting(meetingID) else {
            throw PersistenceError.meetingNotFound(meetingID)
        }
        return meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map { model in
                EmbeddedSegment(
                    segment: TranscriptSegment(
                        id: model.id,
                        text: model.text,
                        startTime: model.startTime,
                        endTime: model.endTime,
                        confidence: model.confidence,
                        capturedAt: model.capturedAt
                    ),
                    vector: model.embeddingDimension > 0 ? model.vector : nil
                )
            }
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
        // Vector is generated here so it commits atomically with the row.
        // Embedding failure (assets missing, empty text) degrades to an
        // unembedded segment that backfillEmbeddings() repairs later.
        var embeddingData = Data()
        var dimension = 0
        if let embedder, let vector = try? embedder.embed(segment.text) {
            embeddingData = vector.withUnsafeBytes { Data($0) }
            dimension = vector.count
        }
        let model = Segment(
            id: segment.id,
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime,
            confidence: segment.confidence,
            capturedAt: segment.capturedAt,
            embeddingData: embeddingData,
            embeddingDimension: dimension
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
