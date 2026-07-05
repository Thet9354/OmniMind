//
//  TranscriptionActor.swift
//  OmniMind
//
//  On-device speech-to-text on the iOS 26 SpeechAnalyzer stack. Consumes the
//  capture stream (any AudioCapturing source — live mic or file replay),
//  converts to the analyzer's preferred format, and emits a single typed
//  stream of volatile/finalized updates. Fully isolated from the main thread.
//

import AVFAudio
import CoreMedia
import Speech

actor TranscriptionActor {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let locale: Locale

    /// Fails fast if the locale is unsupported; downloads the on-device
    /// model asset on first use (§5.5 — callers surface progress/failure
    /// instead of starting a capture that can never transcribe).
    init(locale: Locale = Locale(identifier: "en_US")) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else {
            throw TranscriptionError.localeUnsupported(locale.identifier)
        }
        self.locale = locale

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.assetInstallationFailed
        }

        self.analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    /// Runs the full pump: capture stream → format conversion → analyzer →
    /// typed updates. The returned stream finishes when the capture stream
    /// finishes (source stopped) and all pending results are finalized.
    /// - Parameter archiveURL: when set, the converted audio is also
    ///   encoded to AAC at this location (best-effort; never fails the
    ///   transcription).
    func transcribe(
        _ buffers: AudioBufferStream,
        archivingTo archiveURL: URL? = nil
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        buffers: buffers,
                        archiveURL: archiveURL,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        buffers: AudioBufferStream,
        archiveURL: URL?,
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async throws {
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TranscriptionError.analyzerFormatUnavailable
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        // Results consumer runs concurrently with the audio pump: the
        // analyzer emits volatile hypotheses while audio is still flowing.
        let resultsTask = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if result.isFinal {
                    continuation.yield(.finalized(Self.segment(from: result, text: text)))
                } else {
                    continuation.yield(.volatile(text))
                }
            }
        }

        try await analyzer.start(inputSequence: inputSequence)

        // Optional audio archival of the converted stream — the file's
        // timeline therefore matches segment timestamps exactly.
        var archiveWriter: AudioArchiveWriter?
        if let archiveURL {
            archiveWriter = try? AudioArchiveWriter(url: archiveURL, format: analyzerFormat)
        }

        // Pump. The converter is keyed to the incoming buffer format and
        // rebuilt if it changes mid-stream (route change swapped the mic).
        var converter: AudioFormatConverter?
        for await buffer in buffers {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = try AudioFormatConverter(
                    inputFormat: buffer.format,
                    outputFormat: analyzerFormat
                )
            }
            guard let converter else { continue }
            let converted = try converter.convert(buffer)
            if converted.frameLength > 0 {
                continuation.yield(.audioLevel(AudioLevel.normalizedLevel(of: converted)))
                try? archiveWriter?.write(converted)
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
        }

        // Capture ended: drain the SRC tail (final ~15 ms of speech), close
        // the input, and force the analyzer to finalize pending volatiles.
        if let tail = try converter?.flush(), tail.frameLength > 0 {
            try? archiveWriter?.write(tail)
            inputBuilder.yield(AnalyzerInput(buffer: tail))
        }
        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultsTask.value
    }

    private nonisolated static func segment(
        from result: SpeechTranscriber.Result,
        text: String
    ) -> TranscriptSegment {
        let range = result.range
        let start = range.start.seconds.isFinite ? range.start.seconds : 0
        let duration = range.duration.seconds.isFinite ? range.duration.seconds : 0
        return TranscriptSegment(
            text: text,
            startTime: start,
            endTime: start + duration,
            // SpeechTranscriber does not expose a per-result confidence
            // score; recorded as 1.0 until the API grows one.
            confidence: 1.0
        )
    }
}
