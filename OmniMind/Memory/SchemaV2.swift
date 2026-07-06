//
//  SchemaV2.swift
//  OmniMind
//
//  V2 = V1 + persisted AI outputs on Meeting (summary, cleaned transcript,
//  action items). All additions are optional, so V1 → V2 is a lightweight
//  migration stage. The app codes against the `Meeting`/`Segment`
//  typealiases below — bump them when a V3 lands.
//

import Foundation
import SwiftData

typealias Meeting = SchemaV2.Meeting
typealias Segment = SchemaV2.Segment

nonisolated enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Meeting.self, Segment.self] }

    /// A single captured session. Owns its segments; deleting a meeting
    /// cascade-deletes every segment (and therefore every stored vector).
    ///
    /// AI outputs are persisted here so they survive navigation and
    /// relaunch — regenerating is an explicit user action, never a side
    /// effect of reopening the meeting.
    @Model
    nonisolated final class Meeting {
        @Attribute(.unique) var id: UUID
        var title: String
        var startedAt: Date
        var endedAt: Date?

        /// Generated summary and how it was produced
        /// (`MeetingSynthesizer.Method.rawValue`).
        var summaryText: String?
        var summaryMethod: String?
        /// LLM-repaired transcript; the raw segments always stand untouched.
        var cleanedTranscript: String?
        /// JSON-encoded `[ExtractedActionItem]`. Present-but-empty means
        /// "extraction ran, no commitments found" — distinct from nil
        /// (never extracted).
        var actionItemsData: Data?

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.Segment.meeting)
        var segments: [SchemaV2.Segment] = []

        init(id: UUID = UUID(), title: String, startedAt: Date = .now) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
        }
    }

    /// One finalized transcript segment plus its embedding vector.
    ///
    /// The vector is stored as a contiguous Float32 blob (L2-normalized at
    /// write time, so retrieval-time cosine similarity reduces to a single
    /// dot product). `.externalStorage` keeps vector payloads out of the
    /// primary table rows so metadata scans stay fast.
    @Model
    nonisolated final class Segment {
        @Attribute(.unique) var id: UUID
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Double
        var capturedAt: Date
        var meeting: SchemaV2.Meeting?

        @Attribute(.externalStorage) var embeddingData: Data
        var embeddingDimension: Int

        init(
            id: UUID = UUID(),
            text: String,
            startTime: TimeInterval,
            endTime: TimeInterval,
            confidence: Double,
            capturedAt: Date = .now,
            embeddingData: Data = Data(),
            embeddingDimension: Int = 0
        ) {
            self.id = id
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
            self.confidence = confidence
            self.capturedAt = capturedAt
            self.embeddingData = embeddingData
            self.embeddingDimension = embeddingDimension
        }

        /// Decoded view of `embeddingData`. Copies via `copyBytes` rather
        /// than binding memory, because Data backed by SQLite pages is not
        /// guaranteed to be Float-aligned.
        var vector: [Float] {
            let count = embeddingData.count / MemoryLayout<Float>.stride
            guard count > 0 else { return [] }
            return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                _ = embeddingData.copyBytes(to: buffer)
                initialized = count
            }
        }
    }
}
