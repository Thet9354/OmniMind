//
//  CaptureTests.swift
//  OmniMindTests
//
//  Phase 1 verification suite: format conversion, real-time bridge
//  backpressure accounting, lossless file replay, and stream termination.
//  No microphone or hardware involved — the live AudioStreamActor shares
//  every component under test via the AudioCapturing seam.
//

import AVFAudio
import Foundation
import Testing
@testable import OmniMind

@Suite("Phase 1 — Audio capture graph")
struct CaptureTests {

    // MARK: - Helpers

    /// A deinterleaved Float32 buffer filled with a 440 Hz sine on every
    /// channel — non-silent, deterministic test signal.
    private func makeSineBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let channelData = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                channelData[channel][frame] =
                    sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate)) * 0.5
            }
        }
        return buffer
    }

    private func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            let sample = data[0][frame]
            sum += sample * sample
        }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    /// Writes a 1-second 16 kHz mono sine WAV to the temp directory.
    private func writeTempWAV(frames: AVAudioFrameCount = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnimind-test-\(UUID().uuidString).wav")
        let buffer = try makeSineBuffer(sampleRate: 16_000, channels: 1, frames: frames)
        let file = try AVAudioFile(
            forWriting: url,
            settings: buffer.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return url
    }

    // MARK: - AudioFormatConverter

    @Test("Converter downmixes 48 kHz stereo to 16 kHz mono, preserving signal")
    func convertsToTargetFormat() throws {
        let input = try makeSineBuffer(sampleRate: 48_000, channels: 2, frames: 4_800)
        let converter = try AudioFormatConverter(inputFormat: input.format)
        let output = try converter.convert(input)

        #expect(output.format.sampleRate == 16_000)
        #expect(output.format.channelCount == 1)
        // 4800 frames at a 3:1 ratio → 1600 nominal, minus the SRC filter's
        // priming latency (measured ~240 frames), which stays in the filter
        // until the next buffer or a flush(). Never more than nominal.
        #expect(Int(output.frameLength) <= 1_600)
        #expect(Int(output.frameLength) >= 1_600 - 300)
        // The sine must survive conversion — output is decidedly non-silent.
        #expect(rms(of: output) > 0.1)
    }

    @Test("Converter frame totals converge across a continuous stream")
    func converterConvergesOverStream() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let converter = try AudioFormatConverter(inputFormat: format)

        var totalOut = 0
        let chunks = 20
        let framesPerChunk: AVAudioFrameCount = 4_800
        for _ in 0..<chunks {
            let input = try makeSineBuffer(
                sampleRate: 48_000, channels: 2, frames: framesPerChunk
            )
            let output = try converter.convert(input)
            totalOut += Int(output.frameLength)
        }
        let expected = chunks * 1_600
        // Pre-flush deficit must be one constant filter latency, NOT
        // proportional to chunk count — a converter wrongly rebuilt per call
        // would lose ~200 frames × 20 chunks and fail this hard.
        #expect(abs(totalOut - expected) <= 300)

        // flush() drains the held-back tail; the whole-stream total must
        // then land within a handful of frames of exact.
        if let tail = try converter.flush() {
            totalOut += Int(tail.frameLength)
        }
        #expect(abs(totalOut - expected) <= 64)
    }

    // MARK: - AudioBufferBridge (§5.2 backpressure)

    @Test("Bounded bridge sheds oldest buffers and counts every drop")
    func bridgeShedsAndCounts() async throws {
        let bridge = AudioBufferBridge(capacity: 4)
        let buffer = try makeSineBuffer(sampleRate: 16_000, channels: 1, frames: 160)

        // Producer runs 10 buffers ahead of a consumer that hasn't started —
        // the stall scenario from the failure-mode spec.
        for _ in 0..<10 {
            bridge.yield(buffer)
        }
        bridge.finish()

        #expect(bridge.droppedBufferCount == 6)

        var delivered = 0
        for await _ in bridge.stream {
            delivered += 1
        }
        #expect(delivered == 4)   // only the newest `capacity` survive
    }

    @Test("Unbounded bridge never sheds")
    func unboundedBridgeIsLossless() async throws {
        let bridge = AudioBufferBridge(capacity: nil)
        let buffer = try makeSineBuffer(sampleRate: 16_000, channels: 1, frames: 160)
        for _ in 0..<100 {
            bridge.yield(buffer)
        }
        bridge.finish()

        #expect(bridge.droppedBufferCount == 0)
        var delivered = 0
        for await _ in bridge.stream {
            delivered += 1
        }
        #expect(delivered == 100)
    }

    // MARK: - FileAudioSource

    @Test("File source replays every frame of the file, then finishes")
    func fileSourceStreamsEntireFile() async throws {
        let url = try writeTempWAV(frames: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FileAudioSource(url: url, chunkFrames: 4_096)
        var totalFrames: AVAudioFrameCount = 0
        var bufferCount = 0
        for await buffer in try await source.bufferStream() {
            totalFrames += buffer.frameLength
            bufferCount += 1
            #expect(buffer.format.sampleRate == 16_000)
        }

        #expect(totalFrames == 16_000)      // lossless: every frame delivered
        #expect(bufferCount == 4)           // 4096 + 4096 + 4096 + 3712
    }

    @Test("stop() finishes the stream")
    func stopFinishesStream() async throws {
        let url = try writeTempWAV(frames: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FileAudioSource(url: url)
        let stream = try await source.bufferStream()
        await source.stop()

        // The for-await loop must terminate; a hang here fails via the
        // suite-level timeout rather than asserting.
        for await _ in stream { }
        #expect(Bool(true))
    }
}
