//
//  AudioCapturing.swift
//  OmniMind
//
//  Phase 0 scaffold — implemented by AudioStreamActor in Phase 1.
//

import AVFAudio

/// Abstraction over the live audio capture graph.
///
/// Conforming types own an `AVAudioEngine` and bridge its real-time input tap
/// into structured concurrency via a bounded `AsyncStream`. The real-time tap
/// closure must never block, allocate, or touch actor state — its only legal
/// action is `continuation.yield(_:)`.
///
/// The protocol exists so transcription can be exercised against a
/// file-backed fake in tests without touching real audio hardware.
protocol AudioCapturing: Actor {
    /// Starts the engine and returns a bounded stream of PCM buffers,
    /// already converted to the transcription target format (16 kHz mono).
    /// The stream finishes when `stop()` is called or the engine tears down.
    func bufferStream() throws -> AsyncStream<AVAudioPCMBuffer>

    /// Stops the engine, removes the input tap, and finishes the stream.
    func stop()
}
