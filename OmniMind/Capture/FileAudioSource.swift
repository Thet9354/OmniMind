//
//  FileAudioSource.swift
//  OmniMind
//
//  File-replay conformer to AudioCapturing. Drives the identical downstream
//  pipeline (bridge → converter → transcriber) from an audio file, so
//  transcription accuracy and stream semantics are testable with golden
//  audio — no hardware, no microphone permission, no flakiness.
//

import AVFAudio

actor FileAudioSource: AudioCapturing {
    private let url: URL
    private let chunkFrames: AVAudioFrameCount
    private var bridge: AudioBufferBridge?
    private var readerTask: Task<Void, Never>?

    init(url: URL, chunkFrames: AVAudioFrameCount = 4096) {
        self.url = url
        self.chunkFrames = chunkFrames
    }

    func bufferStream() throws -> AudioBufferStream {
        let file = try AVAudioFile(forReading: url)
        // Unbounded: replay must be lossless — shedding here would silently
        // corrupt a deterministic test transcript. Files are finite.
        let bridge = AudioBufferBridge(capacity: nil)
        self.bridge = bridge

        readerTask = Task {
            let format = file.processingFormat
            while file.framePosition < file.length, !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: chunkFrames
                ) else { break }
                do {
                    try file.read(into: buffer)
                } catch {
                    break
                }
                guard buffer.frameLength > 0 else { break }
                bridge.yield(buffer)
            }
            bridge.finish()
        }
        return bridge.stream
    }

    func stop() {
        readerTask?.cancel()
        readerTask = nil
        bridge?.finish()
        bridge = nil
    }
}
