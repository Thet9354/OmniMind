//
//  MeetingDetailView.swift
//  OmniMind
//
//  Read view of one persisted meeting: AI summary (Pro) on top, transcript
//  below — paged through SegmentPager (§5.1: long meetings render in
//  windows, never as one materialized relationship walk). Export is Pro.
//

import AVFAudio
import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementStore.self) private var entitlements
    @State private var segments: [Segment] = []
    @State private var hasMore = false
    @State private var loaded = false
    @State private var summary: MeetingSynthesizer.Output?
    @State private var summarizing = false
    @State private var cleaned: MeetingSynthesizer.Output?
    @State private var cleaning = false
    @State private var cleanupUnavailable = false
    @State private var actionItems: [ExtractedActionItem]?
    @State private var extractingActions = false
    @State private var actionsUnavailable = false
    @State private var remindersStatus: String?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var showingPaywall = false
    @State private var exportDocument: ExportDocument?

    var body: some View {
        List {
            if !segments.isEmpty {
                summarySection
                actionItemsSection
                cleanupSection
            }
            Section {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    VStack(alignment: .leading, spacing: 4) {
                        // Gap-based turn marker: a silence long enough to
                        // have closed a chunk usually means the floor changed.
                        if index > 0,
                           segment.startTime - segments[index - 1].endTime > 2.5 {
                            Label("pause", systemImage: "ellipsis")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, 2)
                        }
                        HStack(spacing: 6) {
                            Text(Self.timestamp(segment.startTime))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if hasAudio {
                                Image(systemName: "play.circle")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text(segment.text)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if hasAudio { playFrom(segment.startTime) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(hasAudio ? "Plays the audio from this moment" : "")
                }
                if hasMore {
                    Button("Load More Segments") {
                        loadNextPage()
                    }
                }
            } header: {
                Text(meeting.startedAt, format: .dateTime.day().month().year().hour().minute())
            } footer: {
                if hasAudio {
                    Text("Tap any segment to replay its audio.")
                }
            }
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasAudio {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        isPlaying ? "Pause" : "Play",
                        systemImage: isPlaying ? "pause.circle" : "play.circle"
                    ) {
                        togglePlayback()
                    }
                    .accessibilityHint("Plays the meeting audio")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export", systemImage: "square.and.arrow.up") {
                    if entitlements.hasFullAccess {
                        prepareExport()
                    } else {
                        showingPaywall = true
                    }
                }
                .disabled(segments.isEmpty)
                .accessibilityHint("Shares the full transcript as Markdown")
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .sheet(item: $exportDocument) { document in
            ExportSheet(text: document.text)
        }
        .task(id: meeting.id) {
            loadFirstPage()
        }
        .onDisappear {
            player?.stop()
            isPlaying = false
        }
        .overlay {
            if loaded && segments.isEmpty {
                ContentUnavailableView(
                    "Empty Meeting",
                    systemImage: "text.bubble",
                    description: Text("No speech was captured in this session.")
                )
            }
        }
    }

    // MARK: - Playback

    private var hasAudio: Bool {
        AudioArchive.exists(for: meeting.id)
    }

    private func ensurePlayer() -> AVAudioPlayer? {
        if let player { return player }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let loaded = try? AVAudioPlayer(contentsOf: AudioArchive.url(for: meeting.id))
        player = loaded
        return loaded
    }

    private func playFrom(_ time: TimeInterval) {
        guard let player = ensurePlayer() else { return }
        // The archive holds exactly the stream the analyzer timestamped,
        // so segment offsets ARE file offsets.
        player.currentTime = min(time, max(0, player.duration - 0.1))
        player.play()
        isPlaying = true
    }

    private func togglePlayback() {
        guard let player = ensurePlayer() else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    // MARK: - Paging (§5.1)

    private func loadFirstPage() {
        guard !loaded else { return }
        segments = (try? SegmentPager.page(
            in: modelContext, meetingID: meeting.id, offset: 0
        )) ?? []
        hasMore = segments.count == SegmentPager.pageSize
        loaded = true
    }

    private func loadNextPage() {
        let next = (try? SegmentPager.page(
            in: modelContext, meetingID: meeting.id, offset: segments.count
        )) ?? []
        segments.append(contentsOf: next)
        hasMore = next.count == SegmentPager.pageSize
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section("Summary") {
            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.text)
                    Text(summary.method.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            } else if summarizing {
                ProgressView("Summarizing on-device…")
            } else {
                Button("Generate Summary", systemImage: "sparkles") {
                    if entitlements.hasFullAccess {
                        generateSummary()
                    } else {
                        showingPaywall = true
                    }
                }
            }
        }
    }

    // MARK: - Action items

    @ViewBuilder
    private var actionItemsSection: some View {
        Section("Action Items") {
            if let actionItems {
                if actionItems.isEmpty {
                    Text("No commitments were made in this meeting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(actionItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(item.task, systemImage: "circle")
                            if item.owner != nil || item.due != nil {
                                Text([item.owner, item.due]
                                    .compactMap(\.self)
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 28)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button("Add All to Reminders", systemImage: "checklist") {
                        exportToReminders(actionItems)
                    }
                    if let remindersStatus {
                        Text(remindersStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if extractingActions {
                ProgressView("Finding action items on-device…")
            } else if actionsUnavailable {
                Text("Action-item extraction needs Apple Intelligence on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("Find Action Items", systemImage: "checklist") {
                    extractActionItems()
                }
            }
        }
    }

    private func extractActionItems() {
        extractingActions = true
        let container = modelContext.container
        let meetingID = meeting.id
        Task {
            let store = EmbeddingStore(modelContainer: container)
            let all = (try? await store.segments(in: meetingID)) ?? []
            let items = await MeetingSynthesizer().actionItems(from: all)
            actionItems = items
            actionsUnavailable = items == nil
            extractingActions = false
        }
    }

    private func exportToReminders(_ items: [ExtractedActionItem]) {
        let title = meeting.title
        Task {
            do {
                let count = try await RemindersExporter.export(items, sourceTitle: title)
                remindersStatus = "Added \(count) reminder\(count == 1 ? "" : "s")."
            } catch {
                remindersStatus = "Reminders access is needed — enable it in Settings › Privacy."
            }
        }
    }

    // MARK: - Cleanup

    @ViewBuilder
    private var cleanupSection: some View {
        Section("Cleaned Transcript") {
            if let cleaned {
                VStack(alignment: .leading, spacing: 6) {
                    Text(cleaned.text)
                    Text("Repaired on-device — original segments below are untouched.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            } else if cleaning {
                ProgressView("Repairing transcript on-device…")
            } else if cleanupUnavailable {
                Text("Transcript cleanup needs Apple Intelligence on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("Clean Up Transcript", systemImage: "wand.and.sparkles") {
                    cleanTranscript()
                }
            }
        }
    }

    private func cleanTranscript() {
        cleaning = true
        let container = modelContext.container
        let meetingID = meeting.id
        Task {
            let store = EmbeddingStore(modelContainer: container)
            let all = (try? await store.segments(in: meetingID)) ?? []
            let output = await MeetingSynthesizer().cleanTranscript(all)
            cleaned = output
            cleanupUnavailable = output == nil
            cleaning = false
        }
    }

    private func generateSummary() {
        summarizing = true
        let container = modelContext.container
        let meetingID = meeting.id
        Task {
            let store = EmbeddingStore(modelContainer: container)
            let embedded = (try? await store.embeddedSegments(in: meetingID)) ?? []
            let output = await MeetingSynthesizer().summarize(embedded)
            summary = output.text.isEmpty ? nil : output
            summarizing = false
        }
    }

    // MARK: - Export

    private func prepareExport() {
        // Export intentionally reads the FULL transcript, page by page —
        // a one-shot bounded loop, not a resident data structure.
        var all: [(startTime: TimeInterval, text: String)] = []
        var offset = 0
        while let page = try? SegmentPager.page(
            in: modelContext, meetingID: meeting.id, offset: offset
        ), !page.isEmpty {
            all.append(contentsOf: page.map { ($0.startTime, $0.text) })
            offset += page.count
            if page.count < SegmentPager.pageSize { break }
        }
        exportDocument = ExportDocument(text: TranscriptExporter.markdown(
            title: meeting.title,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            segments: all
        ))
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ExportDocument: Identifiable {
    let id = UUID()
    let text: String
}

/// Minimal share wrapper so ShareLink gets a fully rendered document.
private struct ExportSheet: View {
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Transcript Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text)
                }
            }
        }
    }
}

