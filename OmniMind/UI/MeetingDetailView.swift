//
//  MeetingDetailView.swift
//  OmniMind
//
//  Read view of one persisted meeting: timestamped transcript segments.
//

import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    private var orderedSegments: [Segment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        List {
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

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
