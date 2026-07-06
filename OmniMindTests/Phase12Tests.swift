//
//  Phase12Tests.swift
//  OmniMindTests
//
//  Phase 12 verification: the V1 → V2 lightweight migration, persisted AI
//  outputs (summary / cleaned transcript / action items with check-off
//  state), model-placeholder sanitization, and honest playability for
//  crash-stranded audio archives. The route-change capture rebuild is
//  hardware-only and verified on device.
//

import AVFAudio
import Foundation
import SwiftData
import Testing
@testable import OmniMind

// .serialized: the migration test instantiates a live SchemaV1 container,
// and while it exists, concurrent writes to V2-ONLY attributes are silently
// dropped (same entity name resolves against V1 metadata). Only this suite
// touches V2-only fields, so in-suite serialization removes the overlap.
@Suite("Phase 12 — Night-review fixes", .serialized)
struct Phase12Tests {

    // MARK: - Schema migration

    @Test("V1 store migrates lightweight to V2; rows survive, new fields nil")
    func lightweightMigrationV1toV2() throws {
        let url = URL.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed a V1-only store, exactly as the shipped app wrote it.
        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let v1 = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url)]
            )
            let context = ModelContext(v1)
            let meeting = SchemaV1.Meeting(title: "Pre-migration")
            context.insert(meeting)
            let segment = SchemaV1.Segment(
                text: "hello", startTime: 0, endTime: 1, confidence: 1
            )
            segment.meeting = meeting
            context.insert(segment)
            try context.save()
        }   // container deallocates → file handles released

        // Reopen the same file at V2 through the migration plan.
        let schema = Schema(versionedSchema: SchemaV2.self)
        let v2 = try ModelContainer(
            for: schema,
            migrationPlan: OmniMindMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let context = ModelContext(v2)
        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == 1)
        let migrated = try #require(meetings.first)
        #expect(migrated.title == "Pre-migration")
        #expect(migrated.segments.count == 1)
        #expect(migrated.summaryText == nil)
        #expect(migrated.summaryMethod == nil)
        #expect(migrated.cleanedTranscript == nil)
        #expect(migrated.actionItemsData == nil)
    }

    // MARK: - Persisted AI outputs

    @Test("AI outputs round-trip through the store")
    func synthesisArtifactsRoundTrip() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let id = try await store.createMeeting(title: "Persist me")

        try await store.saveSummary("Key points.", method: "On-device AI", for: id)
        try await store.saveCleanedTranscript("Repaired text.", for: id)
        let items = [
            ExtractedActionItem(task: "Send the report", owner: "Ana", due: "Friday"),
            ExtractedActionItem(task: "Book the room", owner: nil, due: nil),
        ]
        try await store.saveActionItems(items, for: id)

        let artifacts = try await store.synthesisArtifacts(for: id)
        #expect(artifacts.summaryText == "Key points.")
        #expect(artifacts.summaryMethod == "On-device AI")
        #expect(artifacts.cleanedTranscript == "Repaired text.")
        #expect(artifacts.actionItems == items)
    }

    @Test("Check-off state and item identity survive a toggle re-save")
    func actionItemTogglePersists() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let id = try await store.createMeeting(title: "Toggles")

        var items = [ExtractedActionItem(task: "Follow up", owner: nil, due: nil)]
        try await store.saveActionItems(items, for: id)

        // The UI toggle path: mutate a copy, re-save wholesale.
        items[0].done = true
        try await store.saveActionItems(items, for: id)

        let reloaded = try #require(
            try await store.synthesisArtifacts(for: id).actionItems
        )
        #expect(reloaded.count == 1)
        #expect(reloaded[0].done)
        #expect(reloaded[0].id == items[0].id)   // stable across encode cycles
    }

    @Test("Present-but-empty action items stay distinct from never-extracted")
    func emptyActionItemsDistinctFromNil() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let id = try await store.createMeeting(title: "No commitments")

        #expect(try await store.synthesisArtifacts(for: id).actionItems == nil)
        try await store.saveActionItems([], for: id)
        #expect(try await store.synthesisArtifacts(for: id).actionItems == [])
    }

    // MARK: - Placeholder sanitization

    @Test("Model placeholder owner/due fields read as absent")
    func placeholderSanitization() {
        #expect(MeetingSynthesizer.sanitizedField("Not specified") == nil)
        #expect(MeetingSynthesizer.sanitizedField("  unknown ") == nil)
        #expect(MeetingSynthesizer.sanitizedField("N/A") == nil)
        #expect(MeetingSynthesizer.sanitizedField("None") == nil)
        #expect(MeetingSynthesizer.sanitizedField("TBD") == nil)
        #expect(MeetingSynthesizer.sanitizedField(nil) == nil)
        #expect(MeetingSynthesizer.sanitizedField("") == nil)
        #expect(MeetingSynthesizer.sanitizedField("   ") == nil)
        #expect(MeetingSynthesizer.sanitizedField("Priya") == "Priya")
        #expect(MeetingSynthesizer.sanitizedField(" by Friday ") == "by Friday")
    }

    // MARK: - Archive playability

    @Test("A crash-stranded archive exists on disk but reports unplayable")
    func corruptArchiveUnplayable() throws {
        let id = UUID()
        defer { AudioArchive.delete(for: id) }
        try AudioArchive.ensureDirectory()
        // An m4a whose header was never finalized is indistinguishable from
        // junk to the reader — model it as junk.
        try Data(repeating: 0xAB, count: 4_096).write(to: AudioArchive.url(for: id))
        #expect(AudioArchive.exists(for: id))
        #expect(!AudioArchive.isPlayable(for: id))
    }
}
