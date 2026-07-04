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
    /// Starts capture and returns a stream of PCM buffers in the source's
    /// native format (consumers convert downstream — see AudioFormatConverter).
    /// The stream finishes when `stop()` is called or the source tears down.
    func bufferStream() throws -> AudioBufferStream

    /// Stops the engine, removes the input tap, and finishes the stream.
    func stop()
}
