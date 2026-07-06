//
//  Phase13Tests.swift
//  OmniMindTests
//
//  Phase 13 verification: the portable meeting-bundle wire format and the
//  export → import round trip across two independent stores (the two-device
//  scenario, minus AirDrop). The share-sheet/onOpenURL plumbing is UI and
//  verified on device.
//

import Foundation
import SwiftData
import Testing
@testable import OmniMind

@Suite("Phase 13 — Meeting bundle sharing")
struct Phase13Tests {

    private static func sampleBundle(id: UUID = UUID()) -> MeetingBundle {
        MeetingBundle(
            id: id,
            title: "Q3 Planning",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            endedAt: Date(timeIntervalSince1970: 1_750_003_600),
            summaryText: "Budget approved; launch moved to October.",
            summaryMethod: "On-device AI",
            cleanedTranscript: "A cleaner rendition.",
            actionItems: [
                ExtractedActionItem(task: "Send the report", owner: "Ana", due: "Friday"),
            ],
            segments: [
                MeetingBundle.BundleSegment(
                    id: UUID(), text: "Kickoff and agenda.",
                    startTime: 0, endTime: 4, confidence: 1,
                    capturedAt: Date(timeIntervalSince1970: 1_750_000_004)
                ),
                MeetingBundle.BundleSegment(
                    id: UUID(), text: "Budget review.",
                    startTime: 5, endTime: 9, confidence: 1,
                    capturedAt: Date(timeIntervalSince1970: 1_750_000_009)
                ),
            ]
        )
    }

    // MARK: - Wire format

    @Test("Codec round-trips metadata and audio bytes exactly")
    func codecRoundTrip() throws {
        let bundle = Self.sampleBundle()
        let audio = Data((0..<10_000).map { UInt8($0 % 251) })

        let encoded = try MeetingBundleCodec.encode(bundle, audio: audio)
        let decoded = try MeetingBundleCodec.decode(encoded)
        #expect(decoded.bundle == bundle)
        #expect(decoded.audio == audio)
    }

    @Test("Audio-less bundles decode with nil audio")
    func codecNoAudio() throws {
        let encoded = try MeetingBundleCodec.encode(Self.sampleBundle(), audio: nil)
        let decoded = try MeetingBundleCodec.decode(encoded)
        #expect(decoded.audio == nil)
    }

    @Test("Garbage, truncation, and future versions are rejected, never trapped")
    func codecRejectsBadInput() throws {
        // Random junk.
        #expect(throws: MeetingBundleError.notABundle) {
            try MeetingBundleCodec.decode(Data(repeating: 0x5A, count: 512))
        }
        // Too short to even carry a header.
        #expect(throws: MeetingBundleError.notABundle) {
            try MeetingBundleCodec.decode(Data("OMNI".utf8))
        }
        // A future format digit must be refused, not misparsed.
        var future = try MeetingBundleCodec.encode(Self.sampleBundle(), audio: nil)
        future.replaceSubrange(7..<8, with: Data("9".utf8))
        #expect(throws: MeetingBundleError.unsupportedVersion) {
            try MeetingBundleCodec.decode(future)
        }
        // A forged length prefix larger than the file must not trap.
        var truncated = try MeetingBundleCodec.encode(Self.sampleBundle(), audio: nil)
        truncated.replaceSubrange(8..<16, with: Data(repeating: 0xFF, count: 8))
        #expect(throws: MeetingBundleError.corrupt) {
            try MeetingBundleCodec.decode(truncated)
        }
    }

    @Test("Share filenames strip path-hostile characters and never go empty")
    func filenames() {
        #expect(MeetingBundleCodec.filename(for: "Q3 Planning") == "Q3 Planning.omnimind")
        #expect(!MeetingBundleCodec.filename(for: "a/b\\c:d?e").contains("/"))
        #expect(MeetingBundleCodec.filename(for: "///") == "Meeting.omnimind")
        #expect(MeetingBundleCodec.filename(for: String(repeating: "x", count: 200)).count <= 60 + ".omnimind".count)
    }

    // MARK: - Two-store round trip (the two-device scenario)

    @Test("Export from one store imports intact into another")
    func exportImportRoundTrip() async throws {
        // Sender device.
        let sender = EmbeddingStore(
            modelContainer: try ModelContainerFactory.make(inMemory: true)
        )
        let meetingID = try await sender.createMeeting(title: "Shared standup")
        try await sender.persist(
            [
                TranscriptSegment(text: "First point.", startTime: 0, endTime: 3, confidence: 1),
                TranscriptSegment(text: "Second point.", startTime: 4, endTime: 8, confidence: 1),
            ],
            into: meetingID
        )
        try await sender.endMeeting(meetingID)
        try await sender.saveSummary("Two points.", method: "On-device AI", for: meetingID)
        let items = [ExtractedActionItem(task: "Follow up", owner: nil, due: nil)]
        try await sender.saveActionItems(items, for: meetingID)

        let exported = try await sender.exportBundle(for: meetingID)
        let wire = try MeetingBundleCodec.encode(exported, audio: nil)

        // Receiver device: a completely separate store.
        let receiver = EmbeddingStore(
            modelContainer: try ModelContainerFactory.make(inMemory: true)
        )
        let received = try MeetingBundleCodec.decode(wire).bundle
        let importedID = try await receiver.importMeeting(received)
        #expect(importedID == meetingID)   // identity preserved end-to-end

        let segments = try await receiver.segments(in: importedID)
        #expect(segments.map(\.text) == ["First point.", "Second point."])
        let artifacts = try await receiver.synthesisArtifacts(for: importedID)
        #expect(artifacts.summaryText == "Two points.")
        #expect(artifacts.actionItems == items)
    }

    @Test("Re-importing the same meeting is refused by identity")
    func duplicateImportRefused() async throws {
        let store = EmbeddingStore(
            modelContainer: try ModelContainerFactory.make(inMemory: true)
        )
        let bundle = Self.sampleBundle()
        _ = try await store.importMeeting(bundle)
        await #expect(throws: PersistenceError.meetingAlreadyExists(bundle.id)) {
            try await store.importMeeting(bundle)
        }
    }

    @Test("Imported segments arrive unembedded and are backfill-repairable")
    func importedSegmentsAwaitBackfill() async throws {
        let store = EmbeddingStore(
            modelContainer: try ModelContainerFactory.make(inMemory: true)
        )
        let id = try await store.importMeeting(Self.sampleBundle())
        // Without embedding assets (simulator), imported rows must land as
        // dimension-0 — exactly the shape backfillEmbeddings() repairs.
        let embedded = try await store.embeddedSegments(in: id)
        #expect(embedded.count == 2)
        #expect(embedded.allSatisfy { $0.vector == nil })
    }
}
