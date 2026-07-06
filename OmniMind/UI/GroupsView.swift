//
//  GroupsView.swift
//  OmniMind
//
//  Shared meeting libraries. A group lives in the owner's personal
//  iCloud (zone-wide CKShare); members are invited through the system
//  collaboration sheet and publish/import meetings as Phase 13 bundles.
//  OmniMind runs no server and can read none of it.
//

import CloudKit
import Combine
import SwiftData
import SwiftUI

// MARK: - Invitation (system collaboration sheet)

/// ShareLink payload: hands the zone-wide CKShare to the system UI, which
/// renders the Messages/Mail collaboration invite.
struct GroupInvite: Transferable {
    let share: CKShare
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { invite in
            .existing(
                invite.share,
                container: CKContainer(identifier: GroupSchema.containerID)
            )
        }
    }
}

// MARK: - Groups list

@MainActor
@Observable
final class GroupsViewModel {
    enum State: Equatable {
        case loading
        case noAccount
        case ready
        case failed
    }

    private(set) var state: State = .loading
    private(set) var groups: [MeetingGroup] = []
    private(set) var creating = false

    private let store = GroupSyncStore()

    func load() async {
        guard await store.isAccountAvailable() else {
            state = .noAccount
            return
        }
        do {
            groups = try await store.myGroups()
            state = .ready
        } catch {
            state = .failed
        }
    }

    func create(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !creating else { return }
        creating = true
        defer { creating = false }
        if let group = try? await store.createGroup(named: trimmed) {
            groups.append(group)
            groups.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    func deleteOrLeave(_ group: MeetingGroup) async {
        try? await store.deleteOrLeave(group)
        groups.removeAll { $0.zoneID == group.zoneID }
    }
}

struct GroupsView: View {
    @State private var model = GroupsViewModel()
    @State private var showingCreate = false
    @State private var newGroupName = ""

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Checking iCloud…")
                case .noAccount:
                    ContentUnavailableView(
                        "iCloud Required",
                        systemImage: "icloud.slash",
                        description: Text("Groups live in your personal iCloud. Sign in to iCloud in Settings to create or join one.")
                    )
                case .failed:
                    ContentUnavailableView(
                        "Groups Unavailable",
                        systemImage: "exclamationmark.icloud",
                        description: Text("Couldn't reach iCloud. Check your connection and pull to retry.")
                    )
                case .ready:
                    if model.groups.isEmpty {
                        ContentUnavailableView(
                            "No Groups Yet",
                            systemImage: "person.3",
                            description: Text("Create a group for a team, class, or project. Members see every meeting published to it — synced through iCloud, never a server.")
                        )
                    } else {
                        groupList
                    }
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Group", systemImage: "plus") {
                        showingCreate = true
                    }
                    .disabled(model.state != .ready)
                }
            }
            .alert("New Group", isPresented: $showingCreate) {
                TextField("Name (e.g. Design Team)", text: $newGroupName)
                Button("Create") {
                    let name = newGroupName
                    newGroupName = ""
                    Task { await model.create(named: name) }
                }
                Button("Cancel", role: .cancel) { newGroupName = "" }
            } message: {
                Text("The group is stored in your iCloud. You choose who to invite next.")
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .onReceive(
                NotificationCenter.default.publisher(for: .omniMindGroupInviteAccepted)
            ) { _ in
                Task { await model.load() }
            }
        }
    }

    private var groupList: some View {
        List {
            ForEach(model.groups) { group in
                NavigationLink {
                    GroupDetailView(group: group)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.headline)
                        Text(group.isOwner ? "You own this group" : "Member")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(group.isOwner ? "Delete" : "Leave", role: .destructive) {
                        Task { await model.deleteOrLeave(group) }
                    }
                }
            }
        }
    }
}

// MARK: - One group

@MainActor
@Observable
final class GroupDetailViewModel {
    enum State: Equatable {
        case loading
        case ready
        case failed
    }

    let group: MeetingGroup
    private(set) var state: State = .loading
    private(set) var items: [SharedMeetingItem] = []
    private(set) var invite: GroupInvite?
    private(set) var publishing = false
    private(set) var statusMessage: String?

    private let store = GroupSyncStore()

    init(group: MeetingGroup) {
        self.group = group
    }

    func load() async {
        do {
            items = try await store.meetings(in: group)
            state = .ready
        } catch {
            state = .failed
        }
        // Every member holds the share, so anyone can grow the group.
        if invite == nil, let share = try? await store.share(for: group) {
            invite = GroupInvite(share: share, name: group.name)
        }
    }

    /// Encode locally (same bytes as an AirDropped bundle), upload as one
    /// record. Re-publishing the same meeting updates in place.
    func publish(meetingID: UUID, container: ModelContainer) async {
        guard !publishing else { return }
        publishing = true
        statusMessage = nil
        defer { publishing = false }

        let embeddingStore = EmbeddingStore(modelContainer: container)
        guard let bundle = try? await embeddingStore.exportBundle(for: meetingID) else {
            statusMessage = "Couldn't read that meeting."
            return
        }
        let audio = AudioArchive.isPlayable(for: meetingID)
            ? try? Data(contentsOf: AudioArchive.url(for: meetingID))
            : nil
        guard let data = try? MeetingBundleCodec.encode(bundle, audio: audio) else {
            statusMessage = "Couldn't package that meeting."
            return
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(meetingID.uuidString).omnimind")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            try data.write(to: fileURL, options: .atomic)
            try await store.publish(
                bundle: bundle,
                encodedBundleFileURL: fileURL,
                hasAudio: audio != nil,
                to: group
            )
            statusMessage = "Published “\(bundle.title)”."
            await load()
        } catch {
            statusMessage = "Publishing failed — check your connection."
        }
    }

    func remove(_ item: SharedMeetingItem) async {
        try? await store.removeMeeting(item, from: group)
        items.removeAll { $0.recordID == item.recordID }
    }
}

struct GroupDetailView: View {
    @State private var model: GroupDetailViewModel
    @Environment(\.modelContext) private var modelContext
    @Query private var localMeetings: [Meeting]
    @State private var showingPublishPicker = false
    @State private var pendingImport: PendingMeetingImport?
    @State private var importFailed = false

    init(group: MeetingGroup) {
        _model = State(initialValue: GroupDetailViewModel(group: group))
    }

    private var localMeetingIDs: Set<UUID> {
        Set(localMeetings.map(\.id))
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading group…")
            case .failed:
                ContentUnavailableView(
                    "Couldn't Load Group",
                    systemImage: "exclamationmark.icloud",
                    description: Text("Check your connection and pull to retry.")
                )
            case .ready:
                meetingList
            }
        }
        .navigationTitle(model.group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let invite = model.invite {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: invite,
                        preview: SharePreview(invite.name, image: Image(systemName: "person.3"))
                    ) {
                        Label("Invite", systemImage: "person.badge.plus")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Publish", systemImage: "square.and.arrow.up.on.square") {
                    showingPublishPicker = true
                }
                .disabled(model.publishing || localMeetings.isEmpty)
                .accessibilityHint("Publishes one of your meetings to this group")
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $showingPublishPicker) {
            publishPicker
        }
        .sheet(item: $pendingImport) { pending in
            MeetingImportView(pending: pending)
        }
        .alert("Couldn't Open Meeting", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The shared meeting couldn't be read. Pull to refresh and try again.")
        }
    }

    private var meetingList: some View {
        List {
            if model.publishing {
                Section {
                    ProgressView("Publishing to the group…")
                }
            }
            if let status = model.statusMessage {
                Section {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if model.items.isEmpty {
                    Text("Nothing here yet. Publish a meeting — every member will see it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.items) { item in
                        sharedMeetingRow(item)
                    }
                }
            } header: {
                Text("Shared Meetings")
            } footer: {
                Text("Synced through the group owner's iCloud. Tap a meeting to import it into your library.")
            }
        }
    }

    private func sharedMeetingRow(_ item: SharedMeetingItem) -> some View {
        let alreadyImported = item.meetingID.map(localMeetingIDs.contains) ?? false
        return Button {
            beginImport(item)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(
                        "\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.segmentCount) segments\(item.hasAudio ? " · audio" : "")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if alreadyImported {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Already in your library")
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Import")
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(alreadyImported)
        .swipeActions {
            Button("Remove", role: .destructive) {
                Task { await model.remove(item) }
            }
        }
    }

    private func beginImport(_ item: SharedMeetingItem) {
        guard let fileURL = item.bundleFileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? MeetingBundleCodec.decode(data)
        else {
            importFailed = true
            return
        }
        pendingImport = PendingMeetingImport(
            bundle: decoded.bundle, audio: decoded.audio
        )
    }

    private var publishPicker: some View {
        NavigationStack {
            List(localMeetings) { meeting in
                Button {
                    showingPublishPicker = false
                    let container = modelContext.container
                    let id = meeting.id
                    Task { await model.publish(meetingID: id, container: container) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .foregroundStyle(.primary)
                        Text(meeting.startedAt, format: .dateTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Publish a Meeting")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    GroupsView()
        .modelContainer(try! ModelContainerFactory.make(inMemory: true))
}
