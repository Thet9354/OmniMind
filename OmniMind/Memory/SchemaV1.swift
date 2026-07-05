//
//  SchemaV1.swift
//  OmniMind
//
//  Versioned SwiftData schema. All future migrations hang off this root
//  via a SchemaMigrationPlan; never mutate a shipped version in place.
//

import Foundation
import SwiftData

nonisolated enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Meeting.self, Segment.self] }
}

/// A single captured session. Owns its segments; deleting a meeting
/// cascade-deletes every segment (and therefore every stored vector).
@Model
nonisolated final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Segment.meeting)
    var segments: [Segment] = []

    init(id: UUID = UUID(), title: String, startedAt: Date = .now) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
    }
}

/// One finalized transcript segment plus its embedding vector.
///
/// The vector is stored as a contiguous Float32 blob (L2-normalized at write
/// time from Phase 4 on, so retrieval-time cosine similarity reduces to a
/// single dot product). `.externalStorage` keeps vector payloads out of the
/// primary table rows so metadata scans stay fast.
@Model
nonisolated final class Segment {
    @Attribute(.unique) var id: UUID
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double
    var capturedAt: Date
    var meeting: Meeting?

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

    /// Decoded view of `embeddingData`. Copies via `copyBytes` rather than
    /// binding memory, because Data backed by SQLite pages is not guaranteed
    /// to be Float-aligned.
    var vector: [Float] {
        let count = embeddingData.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            _ = embeddingData.copyBytes(to: buffer)
            initialized = count
        }
    }
}
