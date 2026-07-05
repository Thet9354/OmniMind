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
import SwiftData

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
    /// Newest finals only (§5.1) — the store holds the full record, so a
    /// 3-hour session costs the live view the same memory as a 3-minute one.
    private(set) var liveTail = TailBuffer<TranscriptSegment>(capacity: 50)
    /// Non-fatal: capture keeps running even if a save fails.
    private(set) var persistenceWarning: String?
    /// §5.2 backpressure telemetry, polled from the capture bridge.
    private(set) var droppedBuffers = 0

    var isDegraded: Bool { droppedBuffers > 0 }

    private var capture: AudioStreamActor?
    private var sessionTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var store: EmbeddingStore?
    private var meetingID: UUID?

    var isRecording: Bool { status == .recording || status == .preparing }

    /// Called once from the view with the app's container. Without a store
    /// (e.g. previews) the session still runs, capture-only.
    func attach(container: ModelContainer) {
        guard store == nil else { return }
        store = EmbeddingStore(modelContainer: container)
    }

    func start() {
        guard sessionTask == nil else { return }
        liveTail.removeAll()
        volatileText = ""
        persistenceWarning = nil
        droppedBuffers = 0
        meetingID = nil
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
            healthTask?.cancel()
            healthTask = nil
            sessionTask = nil
            capture = nil
        }
        status = .preparing

        guard await AVAudioApplication.requestRecordPermission() else {
            status = .failed("Microphone access is required to capture meetings.")
            return
        }

        // Warm the embedding model alongside the speech model. Non-fatal:
        // segments persist unembedded and are backfilled when assets land.
        if let store {
            try? await store.prepareEmbedder()
        }

        do {
            let transcription = try await TranscriptionActor()
            let capture = AudioStreamActor()
            self.capture = capture
            let buffers = try await capture.bufferStream()
            status = .recording
            startHealthPolling(for: capture)

            for try await update in await transcription.transcribe(buffers) {
                switch update {
                case .volatile(let text):
                    volatileText = text
                case .finalized(let segment):
                    liveTail.append(segment)
                    volatileText = ""
                    await persistFinal(segment)
                }
            }
            await closeMeeting()
            status = .idle
        } catch let error as TranscriptionError {
            status = .failed(Self.message(for: error))
            await capture?.stop()
        } catch {
            status = .failed(error.localizedDescription)
            await capture?.stop()
        }
    }

    /// Polls the bridge's shed counter so sustained backpressure surfaces
    /// in the UI as a degraded-capture warning instead of silent data loss.
    private func startHealthPolling(for capture: AudioStreamActor) {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.droppedBuffers = await capture.droppedBufferCount
            }
        }
    }

    /// Lazily creates the meeting on the FIRST final — abandoned sessions
    /// that never produced speech leave no empty rows behind.
    private func persistFinal(_ segment: TranscriptSegment) async {
        guard let store else { return }
        do {
            if meetingID == nil {
                meetingID = try await store.createMeeting(
                    title: Self.defaultTitle(for: .now)
                )
            }
            if let meetingID {
                try await store.persist(segment, into: meetingID)
            }
        } catch {
            persistenceWarning = "Some segments couldn't be saved."
        }
    }

    private func closeMeeting() async {
        guard let store, let meetingID else { return }
        try? await store.endMeeting(meetingID)
    }

    private nonisolated static func defaultTitle(for date: Date) -> String {
        "Capture \(date.formatted(date: .abbreviated, time: .shortened))"
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
