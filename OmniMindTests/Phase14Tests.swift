//
//  Phase14Tests.swift
//  OmniMindTests
//
//  Phase 14 verification: the pure CKRecord mapping layer for shared
//  meeting libraries. The CloudKit server round trip (zones, shares,
//  invite acceptance) cannot run in tests and is verified on devices
//  with two Apple IDs — everything testable without a server is here.
//

import CloudKit
import Foundation
import Testing
@testable import OmniMind

@Suite("Phase 14 — Group record mapping")
struct Phase14Tests {

    private static let zoneID = CKRecordZone.ID(
        zoneName: GroupSchema.newZoneName(), ownerName: CKCurrentUserDefaultName
    )

    private static func sampleBundle(id: UUID = UUID()) -> MeetingBundle {
        MeetingBundle(
            id: id,
            title: "Design Sync",
            startedAt: Date(timeIntervalSince1970: 1_751_000_000),
            endedAt: nil,
            summaryText: nil,
            summaryMethod: nil,
            cleanedTranscript: nil,
            actionItems: nil,
            segments: [
                MeetingBundle.BundleSegment(
                    id: UUID(), text: "Hello", startTime: 0, endTime: 2,
                    confidence: 1, capturedAt: .now
                ),
            ]
        )
    }

    @Test("Group zones are namespaced; foreign zones are never groups")
    func zoneNamespacing() {
        #expect(GroupSchema.isGroupZone(Self.zoneID))
        let foreign = CKRecordZone.ID(
            zoneName: "com.apple.coredata.cloudkit.zone",
            ownerName: CKCurrentUserDefaultName
        )
        #expect(!GroupSchema.isGroupZone(foreign))
        #expect(GroupSchema.newZoneName() != GroupSchema.newZoneName())
    }

    @Test("Meeting UUID is the record name — republish converges, never duplicates")
    func recordIdentity() {
        let meetingID = UUID()
        let a = GroupRecordMapper.meetingRecordID(meetingID: meetingID, in: Self.zoneID)
        let b = GroupRecordMapper.meetingRecordID(meetingID: meetingID, in: Self.zoneID)
        #expect(a == b)
        #expect(a.recordName == meetingID.uuidString)
    }

    @Test("Record ↔ item mapping round-trips the listing metadata")
    func recordItemRoundTrip() throws {
        let bundle = Self.sampleBundle()
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-\(UUID().uuidString).omnimind")
        try Data("payload".utf8).write(to: assetURL)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        let record = GroupRecordMapper.meetingRecord(
            bundle: bundle, bundleFileURL: assetURL, in: Self.zoneID
        )
        GroupRecordMapper.markHasAudio(record, hasAudio: true)

        let item = try #require(GroupRecordMapper.item(from: record))
        #expect(item.meetingID == bundle.id)
        #expect(item.title == "Design Sync")
        #expect(item.startedAt == bundle.startedAt)
        #expect(item.segmentCount == 1)
        #expect(item.hasAudio)
        #expect(item.bundleFileURL != nil)
    }

    @Test("Foreign record types and incomplete records map to nil, not garbage")
    func rejectsForeignRecords() {
        let wrongType = CKRecord(
            recordType: "SomethingElse",
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.zoneID)
        )
        #expect(GroupRecordMapper.item(from: wrongType) == nil)

        let missingFields = CKRecord(
            recordType: GroupSchema.meetingRecordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.zoneID)
        )
        #expect(GroupRecordMapper.item(from: missingFields) == nil)
    }

    @Test("Group info record carries the display name; absence degrades to a default")
    func infoRecordName() {
        let info = GroupRecordMapper.infoRecord(name: "CS Lectures", in: Self.zoneID)
        #expect(GroupRecordMapper.groupName(from: info) == "CS Lectures")
        #expect(info.recordID.recordName == GroupSchema.infoRecordName)
        #expect(GroupRecordMapper.groupName(from: nil) == "Shared Group")
    }

    @Test("Owners write to the private database, members to the shared one")
    func databaseScopes() {
        let owned = MeetingGroup(zoneID: Self.zoneID, name: "Mine", isOwner: true)
        let joined = MeetingGroup(zoneID: Self.zoneID, name: "Theirs", isOwner: false)
        #expect(owned.databaseScope == .private)
        #expect(joined.databaseScope == .shared)
    }
}
