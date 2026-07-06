//
//  TranscriptExporter.swift
//  OmniMind
//
//  Pure Markdown rendering of a meeting transcript. Takes plain values so
//  it is trivially testable and never touches live models.
//

import Foundation

nonisolated enum TranscriptExporter {
    static func markdown(
        title: String,
        startedAt: Date,
        endedAt: Date?,
        segments: [(startTime: TimeInterval, text: String)]
    ) -> String {
        var lines: [String] = []
        lines.append("# \(title)")

        var dateLine = startedAt.formatted(date: .abbreviated, time: .shortened)
        if let endedAt {
            dateLine += " – \(endedAt.formatted(date: .omitted, time: .shortened))"
        }
        lines.append("_\(dateLine)_")
        lines.append("")

        // One paragraph per segment, blank-line separated: the export is
        // read as plain text at least as often as rendered Markdown, so it
        // must scan cleanly raw — no bold markers, no wall of text.
        for segment in segments {
            lines.append("[\(timestamp(segment.startTime))] \(segment.text)")
            lines.append("")
        }

        lines.append("---")
        lines.append("_Transcribed on-device by OmniMind._")
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
