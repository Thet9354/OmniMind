//
//  ContentView.swift
//  OmniMind
//
//  Root shell. Renders from a windowed @Query, never from in-memory
//  accumulations — see the §5.1 memory invariant. Free tier reads the
//  ProCatalog gates: newest N meetings visible, semantic search Pro-only.
//  Capture is never gated.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \Meeting.startedAt, order: .reverse)
    private var meetings: [Meeting]
    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementStore.self) private var entitlements
    @State private var showingRecorder = false
    @State private var showingSearch = false
    @State private var showingPaywall = false

    private var visibleMeetings: [Meeting] {
        entitlements.hasFullAccess
            ? meetings
            : Array(meetings.prefix(ProductCatalog.freeMeetingLimit))
    }

    private var lockedCount: Int {
        entitlements.hasFullAccess
            ? 0
            : max(0, meetings.count - ProductCatalog.freeMeetingLimit)
    }

    var body: some View {
        NavigationStack {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView(
                        "No Meetings Yet",
                        systemImage: "waveform.badge.mic",
                        description: Text(
                            "Start a capture to see live, on-device transcription here."
                        )
                    )
                } else {
                    meetingList
                }
            }
            .navigationTitle("OmniMind")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Search", systemImage: "sparkle.magnifyingglass") {
                        if entitlements.hasFullAccess {
                            showingSearch = true
                        } else {
                            showingPaywall = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Capture", systemImage: "record.circle") {
                        showingRecorder = true
                    }
                }
            }
            .sheet(isPresented: $showingRecorder) {
                RecordingView()
            }
            .sheet(isPresented: $showingSearch) {
                SearchView()
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
        }
    }

    private var meetingList: some View {
        List {
            ForEach(visibleMeetings) { meeting in
                NavigationLink {
                    MeetingDetailView(meeting: meeting)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .font(.headline)
                        Text(
                            "\(meeting.startedAt, format: .dateTime) · \(meeting.segments.count) segments"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteMeetings)

            if lockedCount > 0 {
                Button {
                    showingPaywall = true
                } label: {
                    Label(
                        "Unlock \(lockedCount) older meeting\(lockedCount == 1 ? "" : "s")",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func deleteMeetings(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(visibleMeetings[index])   // cascade removes segments
        }
        try? modelContext.save()
    }
}

#Preview {
    let container = try! ModelContainerFactory.make(inMemory: true)
    return ContentView()
        .modelContainer(container)
        .environment(EntitlementStore())
}
