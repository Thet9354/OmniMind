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
import UIKit

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
    /// Finals accumulating toward the next persisted chunk — rendered
    /// between the saved tail and the volatile hypothesis.
    private(set) var pendingChunkText = ""
    /// BCP-47-ish identifier for the transcription locale (accent variant).
    var preferredLocaleIdentifier = "en_US"
    /// Whether to retain the meeting's audio for tap-to-replay (set from
    /// the view's @AppStorage before each session).
    var keepAudioEnabled = true
    /// Instantaneous input loudness (0...1) for the live level meter.
    private(set) var audioLevel: Float = 0
    /// Set when recording actually starts; drives the elapsed timer.
    private(set) var recordingStartedAt: Date?

    var isDegraded: Bool { droppedBuffers > 0 }

    private var capture: AudioStreamActor?
    private var sessionTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var store: EmbeddingStore?
    private var meetingID: UUID?
    /// Fixed at start() so the audio archive (which begins before the
    /// meeting row exists) shares the meeting's eventual identity.
    private var sessionID = UUID()
    private var coalescer = SegmentCoalescer()
    /// Built ahead of the Record tap so starting is a switch-flip, not a
    /// model spin-up. Consumed per session (analyzers are single-use).
    private var prewarmedTranscription: TranscriptionActor?
    private var prewarmedLocale: String?
    /// Dynamic Island / Lock Screen presence while recording. Best-effort
    /// by contract — a Live Activity failure never touches capture.
    private let liveActivity = RecordingLiveActivityController()

    var isRecording: Bool { status == .recording || status == .preparing }

    /// Called once from the view with the app's container. Without a store
    /// (e.g. previews) the session still runs, capture-only.
    func attach(container: ModelContainer) {
        guard store == nil else { return }
        store = EmbeddingStore(modelContainer: container)
    }

    /// Pays the expensive startup costs (permission prompt, speech model,
    /// embedder) while the user is still looking at the screen, so Record
    /// starts in milliseconds. Safe to call repeatedly; rebuilds only when
    /// the locale changed or the previous prewarm was consumed.
    func prewarm() {
        guard sessionTask == nil else { return }
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            if let store {
                try? await store.prepareEmbedder()
            }
            await prewarmTranscription()
        }
    }

    private func prewarmTranscription() async {
        guard sessionTask == nil else { return }
        guard prewarmedTranscription == nil
                || prewarmedLocale != preferredLocaleIdentifier else { return }
        prewarmedTranscription = try? await TranscriptionActor(
            locale: Locale(identifier: preferredLocaleIdentifier)
        )
        prewarmedLocale = prewarmedTranscription != nil ? preferredLocaleIdentifier : nil
    }

    func start() {
        guard sessionTask == nil else { return }
        liveTail.removeAll()
        volatileText = ""
        pendingChunkText = ""
        persistenceWarning = nil
        droppedBuffers = 0
        meetingID = nil
        sessionID = UUID()
        coalescer.reset()
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
            audioLevel = 0
            recordingStartedAt = nil
            liveActivity.end()
            UIApplication.shared.isIdleTimerDisabled = false
            // Warm up for the NEXT session while the user reviews this one.
            Task { await self.prewarmTranscription() }
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
            // Use the prewarmed analyzer when the locale still matches;
            // analyzers are single-use, so consume it either way.
            let transcription: TranscriptionActor
            if let warmed = prewarmedTranscription,
               prewarmedLocale == preferredLocaleIdentifier {
                transcription = warmed
            } else {
                transcription = try await TranscriptionActor(
                    locale: Locale(identifier: preferredLocaleIdentifier)
                )
            }
            prewarmedTranscription = nil
            prewarmedLocale = nil

            let capture = AudioStreamActor()
            self.capture = capture
            let buffers = try await capture.bufferStream()
            status = .recording
            recordingStartedAt = .now
            UIApplication.shared.isIdleTimerDisabled = true
            startHealthPolling(for: capture)
            liveActivity.start(startedAt: recordingStartedAt ?? .now)

            let archiveURL = keepAudioEnabled ? AudioArchive.url(for: sessionID) : nil
            for try await update in await transcription.transcribe(
                buffers, archivingTo: archiveURL
            ) {
                switch update {
                case .audioLevel(let level):
                    audioLevel = level
                case .volatile(let text):
                    volatileText = text
                case .finalized(let segment):
                    volatileText = ""
                    // Finals route through the coalescer: only coherent
                    // chunks reach the tail view and the store.
                    for chunk in coalescer.ingest(segment) {
                        liveTail.append(chunk)
                        await persistFinal(chunk)
                    }
                    pendingChunkText = coalescer.pendingText
                    pushLiveActivityUpdate()
                }
            }
            if let remainder = coalescer.flush() {
                liveTail.append(remainder)
                await persistFinal(remainder)
            }
            pendingChunkText = ""
            if meetingID == nil {
                // Session produced no meeting — don't strand its audio.
                AudioArchive.delete(for: sessionID)
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
                let wasDegraded = self.isDegraded
                self.droppedBuffers = await capture.droppedBufferCount
                if self.isDegraded != wasDegraded {
                    self.pushLiveActivityUpdate()   // island mirrors the banner
                }
            }
        }
    }

    /// Segment-count/degraded refresh for the Live Activity — called on
    /// coalesced-chunk cadence (a few times a minute), never per volatile.
    private func pushLiveActivityUpdate() {
        guard let startedAt = recordingStartedAt else { return }
        liveActivity.update(
            startedAt: startedAt,
            segmentCount: liveTail.totalAppended,
            isDegraded: isDegraded
        )
    }

    /// Lazily creates the meeting on the FIRST final — abandoned sessions
    /// that never produced speech leave no empty rows behind.
    private func persistFinal(_ segment: TranscriptSegment) async {
        guard let store else { return }
        do {
            if meetingID == nil {
                meetingID = try await store.createMeeting(
                    id: sessionID,
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

        // Auto-title: replace "Capture <date>" with meaning. Fire-and-forget
        // so Stop feels instant; the list row renames itself moments later
        // via @Query observation. nil (no model) keeps the date title.
        let id = meetingID
        Task {
            let segments = (try? await store.segments(in: id)) ?? []
            guard !segments.isEmpty else { return }
            if let title = await MeetingSynthesizer().title(for: segments) {
                try? await store.renameMeeting(id, title: title)
            }
        }
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
