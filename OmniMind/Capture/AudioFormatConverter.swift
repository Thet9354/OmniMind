//
//  AudioFormatConverter.swift
//  OmniMind
//
//  Downstream sample-rate/channel conversion. Deliberately NOT run on the
//  real-time thread: the tap yields raw hardware-format buffers, and the
//  consumer converts on its own executor (§1.2 of the design spec).
//

import AVFAudio

/// Converts arbitrary hardware input formats to the transcription target
/// format: 16 kHz, mono, Float32, deinterleaved.
///
/// Stateful across calls (the SRC filter carries a few frames of delay
/// between buffers), so create one instance per continuous stream and
/// rebuild it if the input format changes mid-stream (e.g. a route change
/// swaps the microphone).
nonisolated final class AudioFormatConverter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.inputFormat = inputFormat
        self.converter = converter
    }

    /// Converts one buffer. Output frame counts vary by ±filter-delay from
    /// the exact rate ratio; totals converge over a stream.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            throw CaptureError.bufferAllocationFailed
        }

        // The input block is @Sendable in the SDK signature but executes
        // synchronously within convert(to:error:) on this thread — the
        // opt-outs below encode that guarantee.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw CaptureError.conversionFailed
        }
        return output
    }

    /// Drains the SRC filter's held-back tail (~150–250 frames at 16 kHz —
    /// the final ~15 ms of speech). Call exactly once, at end of stream;
    /// the converter cannot be reused afterwards.
    func flush() throws -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: 4_096
        ) else {
            throw CaptureError.bufferAllocationFailed
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw CaptureError.conversionFailed
        }
        return output.frameLength > 0 ? output : nil
    }
}
