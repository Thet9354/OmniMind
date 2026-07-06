//
//  OmniMindWidgetsLiveActivity.swift
//  OmniMindWidgets
//
//  Lock Screen and Dynamic Island presentation for an in-progress
//  capture: an elapsed timer (system-rendered — updates cost nothing),
//  saved-segment count, and the degraded-capture warning when the
//  pipeline is shedding audio.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct OmniMindWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // Lock Screen / notification banner.
            HStack(spacing: 12) {
                statusIcon(isDegraded: context.state.isDegraded)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.isDegraded ? "Recording — audio backlogged" : "Recording")
                        .font(.headline)
                    Text("\(context.state.segmentCount) segments saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.state.startedAt, style: .timer)
                    .font(.title3.monospacedDigit())
                    .frame(maxWidth: 64)
            }
            .padding(14)
            .activitySystemActionForegroundColor(.primary)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusIcon(isDegraded: context.state.isDegraded)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .frame(maxWidth: 60)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(
                        context.state.isDegraded
                            ? "Audio is backlogged — some audio may be skipped."
                            : "\(context.state.segmentCount) segments saved on-device."
                    )
                    .font(.caption)
                    .foregroundStyle(context.state.isDegraded ? .orange : .secondary)
                }
            } compactLeading: {
                statusIcon(isDegraded: context.state.isDegraded)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 40)
            } minimal: {
                statusIcon(isDegraded: context.state.isDegraded)
            }
        }
    }

    private func statusIcon(isDegraded: Bool) -> some View {
        Image(systemName: isDegraded ? "exclamationmark.triangle.fill" : "waveform.badge.mic")
            .foregroundStyle(isDegraded ? .orange : .red)
            .symbolRenderingMode(.hierarchical)
    }
}

#Preview(
    "Recording", as: .content,
    using: RecordingActivityAttributes()
) {
    OmniMindWidgetsLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(
        startedAt: .now.addingTimeInterval(-125), segmentCount: 12, isDegraded: false
    )
    RecordingActivityAttributes.ContentState(
        startedAt: .now.addingTimeInterval(-125), segmentCount: 12, isDegraded: true
    )
}
