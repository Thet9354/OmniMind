//
//  SegmentCoalescer.swift
//  OmniMind
//
//  Merges the transcriber's per-utterance finals ("Yeah." / "So Pac-Man.")
//  into coherent chunks before persistence. One fix, four wins: transcripts
//  read as prose, RAG chunks carry enough meaning to embed usefully,
//  summaries get clean input, and timestamps span real passages instead of
//  stuttering every second.
//
//  Flush rules, checked in order on every ingest:
//  1. GAP      — a silence gap over `gapThreshold` closes the pending chunk
//                BEFORE the new segment starts a fresh one (topic boundary).
//  2. SIZE     — reaching `minWords` closes the chunk (enough substance).
//  3. DURATION — exceeding `maxDuration` closes it (bounded chunk length).
//  Stream end: `flush()` emits whatever remains.
//

import Foundation

nonisolated struct SegmentCoalescer {
    struct Configuration: Sendable {
        var minWords = 20
        var maxDuration: TimeInterval = 15
        var gapThreshold: TimeInterval = 2.0
    }

    private let configuration: Configuration
    private var pending: [TranscriptSegment] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Text accumulated but not yet flushed — the UI renders this as the
    /// "hardening" middle layer between volatile hypothesis and saved chunks.
    var pendingText: String {
        pending.map(\.text).joined(separator: " ")
    }

    var hasPending: Bool { !pending.isEmpty }

    /// Feeds one finalized utterance in; returns zero, one, or two chunks
    /// ready to persist (two when a gap closes the old chunk and the new
    /// utterance alone already satisfies a flush rule).
    mutating func ingest(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        var flushed: [TranscriptSegment] = []

        // Rule 1 — silence gap closes the previous chunk first.
        if let last = pending.last,
           segment.startTime - last.endTime > configuration.gapThreshold,
           let chunk = merge(pending) {
            flushed.append(chunk)
            pending.removeAll(keepingCapacity: true)
        }

        pending.append(segment)

        // Rules 2 & 3 — substance or duration.
        let words = pending.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let duration = (pending.last?.endTime ?? 0) - (pending.first?.startTime ?? 0)
        if words >= configuration.minWords || duration >= configuration.maxDuration {
            if let chunk = merge(pending) {
                flushed.append(chunk)
                pending.removeAll(keepingCapacity: true)
            }
        }

        return flushed
    }

    /// Stream ended — emit the remainder, if any.
    mutating func flush() -> TranscriptSegment? {
        defer { pending.removeAll(keepingCapacity: true) }
        return merge(pending)
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    private func merge(_ segments: [TranscriptSegment]) -> TranscriptSegment? {
        guard let first = segments.first, let last = segments.last else { return nil }
        let confidence = segments.reduce(0.0) { $0 + $1.confidence } / Double(segments.count)
        return TranscriptSegment(
            text: segments.map(\.text).joined(separator: " "),
            startTime: first.startTime,
            endTime: last.endTime,
            confidence: confidence,
            capturedAt: first.capturedAt
        )
    }
}
