//
//  MeetingDetailView.swift
//  OmniMind
//
//  Read view of one persisted meeting: AI summary (Pro) on top,
//  timestamped transcript segments below.
//

import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementStore.self) private var entitlements
    @State private var summary: MeetingSynthesizer.Output?
    @State private var summarizing = false
    @State private var showingPaywall = false

    private var orderedSegments: [Segment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        List {
            if !meeting.segments.isEmpty {
                summarySection
            }
            Section {
                ForEach(orderedSegments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.timestamp(segment.startTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(segment.text)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(meeting.startedAt, format: .dateTime.day().month().year().hour().minute())
            }
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .overlay {
            if meeting.segments.isEmpty {
                ContentUnavailableView(
                    "Empty Meeting",
                    systemImage: "text.bubble",
                    description: Text("No speech was captured in this session.")
                )
            }
        }
    }

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
            } else if summarizing {
                ProgressView("Summarizing on-device…")
            } else {
                Button("Generate Summary", systemImage: "sparkles") {
                    if entitlements.isPro {
                        generateSummary()
                    } else {
                        showingPaywall = true
                    }
                }
            }
        }
    }

    private func generateSummary() {
        summarizing = true
        let container = modelContext.container
        let meetingID = meeting.id
        Task {
            let store = EmbeddingStore(modelContainer: container)
            let segments = (try? await store.embeddedSegments(in: meetingID)) ?? []
            let output = await MeetingSynthesizer().summarize(segments)
            summary = output.text.isEmpty ? nil : output
            summarizing = false
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
