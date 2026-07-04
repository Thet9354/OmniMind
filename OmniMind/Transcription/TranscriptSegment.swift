//
//  TranscriptSegment.swift
//  OmniMind
//
//  Phase 0 scaffold — produced by TranscriptionActor from Phase 2 onward.
//

import Foundation

/// A finalized, immutable slice of transcribed speech.
///
/// This is the only type that crosses from the transcription actor into
/// persistence. It is a pure value type — never a SwiftData model, never an
/// attributed string, never an audio buffer — so it is `Sendable` by
/// construction and safe to hand across isolation domains.
nonisolated struct TranscriptSegment: Sendable, Identifiable, Equatable {
    let id: UUID
    let text: String
    /// Offset from the start of the meeting, in seconds.
    let startTime: TimeInterval
    /// Offset from the start of the meeting, in seconds.
    let endTime: TimeInterval
    /// Mean recognizer confidence over the segment's tokens, in 0...1.
    let confidence: Double
    let capturedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double,
        capturedAt: Date = .now
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.capturedAt = capturedAt
    }
}
