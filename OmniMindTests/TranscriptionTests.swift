//
//  TranscriptionTests.swift
//  OmniMindTests
//
//  Phase 2 verification suite. The golden-audio test synthesizes speech with
//  AVSpeechSynthesizer, replays it through FileAudioSource (the same
//  AudioCapturing seam the live mic uses), and asserts word-error-rate
//  against the spoken script — no hardware, no network audio, deterministic
//  input. Gated on on-device speech assets being installable in this
//  environment.
//

import AVFAudio
import Foundation
import Speech
import Testing
@testable import OmniMind

// MARK: - Word error rate

/// Levenshtein distance over normalized word tokens / reference length.
nonisolated func wordErrorRate(reference: String, hypothesis: String) -> Double {
    func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
    let ref = tokens(reference)
    let hyp = tokens(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    guard !hyp.isEmpty else { return 1 }   // all deletions

    var previous = Array(0...hyp.count)
    var current = [Int](repeating: 0, count: hyp.count + 1)
    for i in 1...ref.count {
        current[0] = i
        for j in 1...hyp.count {
            let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
            current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
        }
        swap(&previous, &current)
    }
    return Double(previous[hyp.count]) / Double(ref.count)
}

@Suite("Phase 2 — Transcription")
struct TranscriptionTests {

    // MARK: - WER metric (test the test harness first)

    @Test("WER is 0 for identical strings, robust to case and punctuation")
    func werIdentical() {
        #expect(wordErrorRate(
            reference: "The quick brown fox.",
            hypothesis: "the QUICK, brown fox"
        ) == 0)
    }

    @Test("WER counts substitutions, insertions, deletions")
    func werEdits() {
        #expect(wordErrorRate(reference: "a b c", hypothesis: "a x c") == 1.0 / 3.0)
        #expect(wordErrorRate(reference: "a b c", hypothesis: "a b c d") == 1.0 / 3.0)
        #expect(wordErrorRate(reference: "a b c", hypothesis: "a c") == 1.0 / 3.0)
        #expect(wordErrorRate(reference: "a b c", hypothesis: "") == 1.0)
    }

    // MARK: - Golden audio end-to-end

    /// True when the en_US on-device transcription model is present or
    /// installable here. False skips the E2E gate (e.g. CI without assets)
    /// rather than failing it.
    static func speechModelReady() async -> Bool {
        let locale = Locale(identifier: "en_US")
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else { return false }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
            return true
        } catch {
            return false
        }
    }

    /// Renders speech for the script into a CAF file via AVSpeechSynthesizer.
    private func synthesizeSpeech(_ text: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnimind-tts-\(UUID().uuidString).caf")

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        let synthesizer = AVSpeechSynthesizer()
        nonisolated(unsafe) var file: AVAudioFile?
        nonisolated(unsafe) var writeError: Error?

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var finished = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // Zero-length buffer signals end of synthesis.
                    if !finished {
                        finished = true
                        done.resume()
                    }
                    return
                }
                do {
                    if file == nil {
                        file = try AVAudioFile(
                            forWriting: url,
                            settings: pcm.format.settings,
                            commonFormat: pcm.format.commonFormat,
                            interleaved: pcm.format.isInterleaved
                        )
                    }
                    try file?.write(from: pcm)
                } catch {
                    writeError = error
                    if !finished {
                        finished = true
                        done.resume()
                    }
                }
            }
        }

        if let writeError { throw writeError }
        _ = try #require(file, "TTS produced no audio")
        return url
    }

    @Test(
        "Golden audio transcribes with WER ≤ 0.15; only finals carry segments",
        .enabled("requires installable on-device en_US speech assets") {
            await TranscriptionTests.speechModelReady()
        },
        .timeLimit(.minutes(5))
    )
    func goldenAudioWER() async throws {
        let script = """
        The quarterly budget review is scheduled for Monday morning. \
        Please bring the updated revenue forecast and the hiring plan.
        """

        let url = try await synthesizeSpeech(script)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FileAudioSource(url: url)
        let transcription = try await TranscriptionActor(
            locale: Locale(identifier: "en_US")
        )
        let buffers = try await source.bufferStream()

        var finals: [TranscriptSegment] = []
        var sawVolatile = false
        for try await update in await transcription.transcribe(buffers) {
            switch update {
            case .audioLevel:
                break
            case .volatile:
                sawVolatile = true
            case .finalized(let segment):
                finals.append(segment)
            }
        }

        let hypothesis = finals.map(\.text).joined(separator: " ")
        let wer = wordErrorRate(reference: script, hypothesis: hypothesis)
        #expect(wer <= 0.15, "WER \(wer) — hypothesis: \(hypothesis)")

        // Structural guarantees: finals exist, carry monotonic non-negative
        // timing, and volatile hypotheses never produced segments.
        #expect(!finals.isEmpty)
        for segment in finals {
            #expect(segment.endTime >= segment.startTime)
            #expect(segment.startTime >= 0)
        }
        // Volatile updates are expected for multi-second audio, but their
        // presence depends on model pacing — observed, not asserted.
        _ = sawVolatile
    }
}
