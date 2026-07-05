//
//  RecordingViewModel.swift
//  OmniMind
//
//  Main-actor projection of the capture + transcription pipeline. Owns the
//  actors, routes the typed update stream: volatile → ONE replaceable
//  property (§5.1 — never an append log), finalized → the segments list
//  (and, from Phase 3, the EmbeddingStore).
//

import AVFAudio
import Observation

@MainActor
@Observable
final class RecordingViewModel {
    enum Status: Equatable {
        case idle
        case preparing         // permission + model asset provisioning
        case recording
        case stopping
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// The in-flight hypothesis. Replaced wholesale on every volatile update.
    private(set) var volatileText = ""
    /// Finalized segments for the current session (persisted in Phase 3).
    private(set) var segments: [TranscriptSegment] = []

    private var capture: AudioStreamActor?
    private var sessionTask: Task<Void, Never>?

    var isRecording: Bool { status == .recording || status == .preparing }

    func start() {
        guard sessionTask == nil else { return }
        segments.removeAll()
        volatileText = ""
        sessionTask = Task { await runSession() }
    }

    func stop() {
        guard let capture else { return }
        status = .stopping
        Task { await capture.stop() }
        // The capture stream finishing unwinds the transcription stream,
        // which lets runSession() drain pending finals and reach .idle.
    }

    private func runSession() async {
        defer {
            sessionTask = nil
            capture = nil
        }
        status = .preparing

        guard await AVAudioApplication.requestRecordPermission() else {
            status = .failed("Microphone access is required to capture meetings.")
            return
        }

        do {
            let transcription = try await TranscriptionActor()
            let capture = AudioStreamActor()
            self.capture = capture
            let buffers = try await capture.bufferStream()
            status = .recording

            for try await update in await transcription.transcribe(buffers) {
                switch update {
                case .volatile(let text):
                    volatileText = text
                case .finalized(let segment):
                    segments.append(segment)
                    volatileText = ""
                }
            }
            status = .idle
        } catch let error as TranscriptionError {
            status = .failed(Self.message(for: error))
            await capture?.stop()
        } catch {
            status = .failed(error.localizedDescription)
            await capture?.stop()
        }
    }

    private nonisolated static func message(for error: TranscriptionError) -> String {
        switch error {
        case .localeUnsupported(let id):
            "On-device transcription doesn't support the \(id) locale yet."
        case .assetInstallationFailed:
            "Couldn't download the on-device speech model. Check your connection and free space, then try again."
        case .analyzerFormatUnavailable:
            "The speech engine couldn't negotiate an audio format."
        }
    }
}
