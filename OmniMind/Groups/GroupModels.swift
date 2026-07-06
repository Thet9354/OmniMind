//
//  GroupModels.swift
//  OmniMind
//
//  Value types and pure CKRecord mapping for shared meeting libraries.
//  A group IS a CloudKit record zone (zone-wide CKShare) in the owner's
//  personal iCloud; a published meeting IS one record whose payload is a
//  Phase 13 .omnimind bundle attached as a CKAsset. Everything here that
//  can be tested without a CloudKit server is a pure function.
//
//  Privacy: no OmniMind server exists. Group data lives in the members'
//  iCloud accounts, transport-encrypted by Apple, unreadable by the
//  developer. Only meetings a user explicitly publishes leave the device.
//

import CloudKit
import Foundation

/// GROUPS ARE DORMANT until a paid Apple Developer team is active —
/// Apple does not allow the iCloud/CloudKit capability on free personal
/// teams, and with the entitlement absent, constructing a CKContainer
/// aborts the process. The whole subsystem is built and tested underneath
/// (same pattern as the dormant StoreKit paywall).
///
/// Re-arm procedure (after enrolling / selecting a paid team):
///  1. Xcode → target → Signing & Capabilities → + iCloud → CloudKit
///     (this re-adds CODE_SIGN_ENTITLEMENTS pointing at
///     Config/OmniMind.entitlements, which is already in the repo).
///  2. Flip `enabled` to true.
nonisolated enum GroupsFeature {
    static let enabled = false
}

nonisolated enum GroupSchema {
    static let containerID = "iCloud.com.thetpine.workspace.OmniMind"
    /// Group zones are namespaced so unrelated zones (e.g. a future
    /// SwiftData mirror) never show up as groups.
    static let zonePrefix = "group."
    static let infoRecordType = "GroupInfo"
    static let infoRecordName = "info"
    static let meetingRecordType = "SharedMeeting"

    enum InfoField {
        static let name = "name"
    }

    enum MeetingField {
        static let title = "title"
        static let startedAt = "startedAt"
        static let segmentCount = "segmentCount"
        static let hasAudio = "hasAudio"
        static let bundle = "bundle"
    }

    static func newZoneName() -> String {
        zonePrefix + UUID().uuidString
    }

    static func isGroupZone(_ zoneID: CKRecordZone.ID) -> Bool {
        zoneID.zoneName.hasPrefix(zonePrefix)
    }
}

/// One shared library the user owns or joined.
nonisolated struct MeetingGroup: Identifiable, Sendable, Equatable {
    var id: CKRecordZone.ID { zoneID }
    let zoneID: CKRecordZone.ID
    let name: String
    /// Owners write to the private database; members to the shared one.
    let isOwner: Bool

    var databaseScope: CKDatabase.Scope { isOwner ? .private : .shared }
}

/// One meeting as listed in a group — metadata immediately, the bundle
/// asset downloaded only when the user asks to import.
nonisolated struct SharedMeetingItem: Identifiable, Sendable, Equatable {
    var id: CKRecord.ID { recordID }
    let recordID: CKRecord.ID
    /// The meeting's own UUID (the record name) — lets the UI mark
    /// meetings that are already in the local library.
    let meetingID: UUID?
    let title: String
    let startedAt: Date
    let segmentCount: Int
    let hasAudio: Bool
    /// Local file the bundle asset was downloaded to (present when the
    /// record was fetched with its payload).
    let bundleFileURL: URL?
}

nonisolated enum GroupRecordMapper {
    /// Meeting UUID = record name, so publishing the same meeting twice
    /// (or from two members) converges on one record per meeting.
    static func meetingRecordID(
        meetingID: UUID, in zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: meetingID.uuidString, zoneID: zoneID)
    }

    static func meetingRecord(
        bundle: MeetingBundle,
        bundleFileURL: URL,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: GroupSchema.meetingRecordType,
            recordID: meetingRecordID(meetingID: bundle.id, in: zoneID)
        )
        record[GroupSchema.MeetingField.title] = bundle.title
        record[GroupSchema.MeetingField.startedAt] = bundle.startedAt
        record[GroupSchema.MeetingField.segmentCount] = bundle.segments.count
        record[GroupSchema.MeetingField.hasAudio] = 0
        record[GroupSchema.MeetingField.bundle] = CKAsset(fileURL: bundleFileURL)
        return record
    }

    static func markHasAudio(_ record: CKRecord, hasAudio: Bool) {
        record[GroupSchema.MeetingField.hasAudio] = hasAudio ? 1 : 0
    }

    static func item(from record: CKRecord) -> SharedMeetingItem? {
        guard record.recordType == GroupSchema.meetingRecordType,
              let title = record[GroupSchema.MeetingField.title] as? String,
              let startedAt = record[GroupSchema.MeetingField.startedAt] as? Date
        else { return nil }
        return SharedMeetingItem(
            recordID: record.recordID,
            meetingID: UUID(uuidString: record.recordID.recordName),
            title: title,
            startedAt: startedAt,
            segmentCount: (record[GroupSchema.MeetingField.segmentCount] as? Int) ?? 0,
            hasAudio: ((record[GroupSchema.MeetingField.hasAudio] as? Int) ?? 0) == 1,
            bundleFileURL: (record[GroupSchema.MeetingField.bundle] as? CKAsset)?.fileURL
        )
    }

    static func infoRecord(name: String, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: GroupSchema.infoRecordType,
            recordID: CKRecord.ID(
                recordName: GroupSchema.infoRecordName, zoneID: zoneID
            )
        )
        record[GroupSchema.InfoField.name] = name
        return record
    }

    static func groupName(from record: CKRecord?) -> String {
        (record?[GroupSchema.InfoField.name] as? String) ?? "Shared Group"
    }
}
