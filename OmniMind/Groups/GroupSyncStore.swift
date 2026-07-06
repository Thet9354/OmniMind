//
//  GroupSyncStore.swift
//  OmniMind
//
//  The single CloudKit funnel for shared meeting libraries. Owns the
//  container; UI talks in Sendable value types (MeetingGroup /
//  SharedMeetingItem) and never sees CKRecord. Reads use
//  recordZoneChanges (change-token API) rather than CKQuery, so no
//  CloudKit-dashboard index configuration is ever required.
//
//  v1 refresh model: fetch on appear + pull-to-refresh. Push-driven
//  updates (CKDatabaseSubscription + APNs entitlement) are a later,
//  additive step.
//

import CloudKit
import Foundation

nonisolated enum GroupSyncError: Error {
    case iCloudUnavailable   // no signed-in account
    case notFound
    case underlying(Error)
}

actor GroupSyncStore {
    private let containerID: String
    /// Constructed on first CloudKit touch, not at init: without the
    /// iCloud entitlement (dormant Groups), CKContainer(identifier:)
    /// aborts the process — deferral keeps mere construction safe.
    private lazy var container = CKContainer(identifier: containerID)

    init(containerID: String = GroupSchema.containerID) {
        self.containerID = containerID
    }

    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }

    private func database(for group: MeetingGroup) -> CKDatabase {
        group.isOwner ? privateDB : sharedDB
    }

    // MARK: - Account

    /// Groups need a signed-in iCloud account; everything else in the app
    /// works without one. The UI shows a sign-in prompt state on false.
    func isAccountAvailable() async -> Bool {
        ((try? await container.accountStatus()) ?? .couldNotDetermine) == .available
    }

    // MARK: - Groups

    /// Creates the zone, its display-name record, and the zone-wide share
    /// in one modify operation — a group either fully exists or doesn't.
    func createGroup(named name: String) async throws -> MeetingGroup {
        let zoneID = CKRecordZone.ID(
            zoneName: GroupSchema.newZoneName(), ownerName: CKCurrentUserDefaultName
        )
        do {
            _ = try await privateDB.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: []
            )
            let info = GroupRecordMapper.infoRecord(name: name, in: zoneID)
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = name
            share.publicPermission = .none
            _ = try await privateDB.modifyRecords(
                saving: [info, share], deleting: []
            )
            return MeetingGroup(zoneID: zoneID, name: name, isOwner: true)
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }

    /// Groups the user owns plus groups joined via accepted invites.
    func myGroups() async throws -> [MeetingGroup] {
        guard await isAccountAvailable() else { throw GroupSyncError.iCloudUnavailable }
        do {
            async let owned = privateDB.allRecordZones()
            async let joined = sharedDB.allRecordZones()

            var groups: [MeetingGroup] = []
            for zone in try await owned where GroupSchema.isGroupZone(zone.zoneID) {
                groups.append(MeetingGroup(
                    zoneID: zone.zoneID,
                    name: try await groupName(in: zone.zoneID, database: privateDB),
                    isOwner: true
                ))
            }
            for zone in try await joined where GroupSchema.isGroupZone(zone.zoneID) {
                groups.append(MeetingGroup(
                    zoneID: zone.zoneID,
                    name: try await groupName(in: zone.zoneID, database: sharedDB),
                    isOwner: false
                ))
            }
            return groups.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        } catch let error as GroupSyncError {
            throw error
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }

    private func groupName(
        in zoneID: CKRecordZone.ID, database: CKDatabase
    ) async throws -> String {
        let infoID = CKRecord.ID(
            recordName: GroupSchema.infoRecordName, zoneID: zoneID
        )
        let record = try? await database.record(for: infoID)
        return GroupRecordMapper.groupName(from: record)
    }

    /// The zone-wide share, for inviting members to a group you own.
    func share(for group: MeetingGroup) async throws -> CKShare {
        let shareID = CKRecord.ID(
            recordName: CKRecordNameZoneWideShare, zoneID: group.zoneID
        )
        do {
            guard let share = try await database(for: group)
                .record(for: shareID) as? CKShare
            else { throw GroupSyncError.notFound }
            return share
        } catch let error as GroupSyncError {
            throw error
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }

    /// Owner: deletes the group for everyone. Member: leaves the group
    /// (removes own participation by deleting the share from the shared DB).
    func deleteOrLeave(_ group: MeetingGroup) async throws {
        do {
            if group.isOwner {
                _ = try await privateDB.modifyRecordZones(
                    saving: [], deleting: [group.zoneID]
                )
            } else {
                let shareID = CKRecord.ID(
                    recordName: CKRecordNameZoneWideShare, zoneID: group.zoneID
                )
                _ = try await sharedDB.deleteRecord(withID: shareID)
            }
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }

    // MARK: - Meetings in a group

    /// Full-zone read via the change-token API with a nil token — returns
    /// every live record without needing queryable indexes. Group zones
    /// stay small (dozens of meetings), so a full pass per refresh is fine.
    func meetings(in group: MeetingGroup) async throws -> [SharedMeetingItem] {
        do {
            let changes = try await database(for: group).recordZoneChanges(
                inZoneWith: group.zoneID, since: nil
            )
            return changes.modificationResultsByID.values
                .compactMap { try? $0.get().record }
                .compactMap(GroupRecordMapper.item(from:))
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }

    /// Publishes an encoded .omnimind bundle into the group. Record name =
    /// meeting UUID, so re-publishing updates rather than duplicates.
    func publish(
        bundle: MeetingBundle,
        encodedBundleFileURL: URL,
        hasAudio: Bool,
        to group: MeetingGroup
    ) async throws {
        let record = GroupRecordMapper.meetingRecord(
            bundle: bundle, bundleFileURL: encodedBundleFileURL, in: group.zoneID
        )
        GroupRecordMapper.markHasAudio(record, hasAudio: hasAudio)
        do {
            _ = try await database(for: group).modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys
            )
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }

    /// Removes one published meeting from the group (any member may).
    func removeMeeting(_ item: SharedMeetingItem, from group: MeetingGroup) async throws {
        do {
            _ = try await database(for: group).deleteRecord(withID: item.recordID)
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }

    // MARK: - Invitation acceptance

    /// Called from the app delegate when the user taps a group invite.
    func acceptShare(from metadata: CKShare.Metadata) async throws {
        do {
            _ = try await container.accept(metadata)
        } catch {
            throw GroupSyncError.underlying(error)
        }
    }
}
