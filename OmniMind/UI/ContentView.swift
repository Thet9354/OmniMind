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
    @State private var showingRecorder = false

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
                    List(meetings) { meeting in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title)
                                .font(.headline)
                            Text(meeting.startedAt, format: .dateTime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("OmniMind")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Capture", systemImage: "record.circle") {
                        showingRecorder = true
                    }
                }
            }
            .sheet(isPresented: $showingRecorder) {
                RecordingView()
            }
        }
    }
}

#Preview {
    let container = try! ModelContainerFactory.make(inMemory: true)
    return ContentView()
        .modelContainer(container)
}
