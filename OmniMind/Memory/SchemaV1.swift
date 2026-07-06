//
//  SchemaV1.swift
//  OmniMind
//
//  Versioned SwiftData schema. All future migrations hang off this root
//  via a SchemaMigrationPlan; never mutate a shipped version in place.
//
//  V1 models live nested inside the enum, frozen exactly as shipped, so
//  V2 can define successors under the same entity names. The
//  current-version typealiases (`Meeting`, `Segment`) live in SchemaV2.swift.
//

import Foundation
import SwiftData

nonisolated enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Meeting.self, Segment.self] }

    /// A single captured session. Owns its segments; deleting a meeting
    /// cascade-deletes every segment (and therefore every stored vector).
    @Model
    nonisolated final class Meeting {
        @Attribute(.unique) var id: UUID
        var title: String
        var startedAt: Date
        var endedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.Segment.meeting)
        var segments: [SchemaV1.Segment] = []

        init(id: UUID = UUID(), title: String, startedAt: Date = .now) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
        }
    }

    /// One finalized transcript segment plus its embedding vector.
    @Model
    nonisolated final class Segment {
        @Attribute(.unique) var id: UUID
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Double
        var capturedAt: Date
        var meeting: SchemaV1.Meeting?

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
    }
}
