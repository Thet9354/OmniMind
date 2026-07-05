//
//  ContentView.swift
//  OmniMind
//
//  Root shell. Renders from a windowed @Query, never from in-memory
//  accumulations — see the §5.1 memory invariant.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \Meeting.startedAt, order: .reverse)
    private var meetings: [Meeting]
    @Environment(\.modelContext) private var modelContext
    @State private var showingRecorder = false
    @State private var showingSearch = false

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
                    List {
                        ForEach(meetings) { meeting in
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
                    }
                }
            }
            .navigationTitle("OmniMind")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Search", systemImage: "sparkle.magnifyingglass") {
                        showingSearch = true
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
        }
    }

    private func deleteMeetings(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(meetings[index])   // cascade removes segments
        }
        try? modelContext.save()
    }
}

#Preview {
    let container = try! ModelContainerFactory.make(inMemory: true)
    return ContentView()
        .modelContainer(container)
}
