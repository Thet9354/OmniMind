//
//  AudioStreamActor.swift
//  OmniMind
//
//  Live microphone capture graph. Owns the AVAudioEngine, configures the
//  audio session, and bridges the real-time input tap into structured
//  concurrency via AudioBufferBridge. Survives interruptions (calls, Siri)
//  and route changes (headsets) without tearing down the stream.
//

import AVFAudio

actor AudioStreamActor: AudioCapturing {
    enum State: Equatable {
        case idle
        case running
        case interrupted
    }

    private let engine = AVAudioEngine()
    private var bridge: AudioBufferBridge?
    private var observers: [any NSObjectProtocol] = []
    private(set) var state: State = .idle

    /// Live backpressure telemetry (§5.2). Grows only when the consumer
    /// stalls long enough for the bounded bridge to shed audio.
    var droppedBufferCount: Int {
        bridge?.droppedBufferCount ?? 0
    }

    /// The hardware input format at capture start. Consumers build their
    /// AudioFormatConverter from the format of each received buffer instead
    /// of caching this, so a mid-stream route change stays correct.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    // MARK: - AudioCapturing

    func bufferStream() throws -> AudioBufferStream {
        guard state == .idle else { throw CaptureError.alreadyRunning }

        try configureSession()

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw CaptureError.noInputAvailable
        }

        // ~1 s of headroom at typical 20–90 ms tap callbacks. Beyond that the
        // consumer has stalled and shedding stale audio is the correct move.
        let bridge = AudioBufferBridge(capacity: 48)
        self.bridge = bridge

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            // ── real-time render thread ──
            // The sole legal action here: one lock-free enqueue. No locks,
            // no allocation, no conversion, no actor state (§1.1).
            bridge.yield(buffer)
        }

        installSessionObservers()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw error
        }
        state = .running
        return bridge.stream
    }

    func stop() {
        teardown()
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement gives the flattest input path for ASR; ducking keeps
        // other audio audible but secondary during capture.
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .allowBluetoothHFP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bridge?.finish()
        bridge = nil
        removeSessionObservers()
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - Interruptions & route changes (§5.4)

    private func installSessionObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            let shouldResume: Bool = {
                guard let optionsRaw =
                        note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                else { return false }
                return AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    .contains(.shouldResume)
            }()
            Task { await self.handleInterruption(type: type, shouldResume: shouldResume) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            else { return }
            Task { await self.handleRouteChange(reason: reason) }
        })
    }

    private func removeSessionObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleInterruption(
        type: AVAudioSession.InterruptionType,
        shouldResume: Bool
    ) {
        switch type {
        case .began:
            guard state == .running else { return }
            engine.pause()
            state = .interrupted
        case .ended:
            guard state == .interrupted else { return }
            if shouldResume {
                do {
                    try AVAudioSession.sharedInstance().setActive(
                        true, options: .notifyOthersOnDeactivation
                    )
                    try engine.start()
                    state = .running
                } catch {
                    // Resumption failed (e.g. another app claimed the mic).
                    // End the stream cleanly; the UI transitions to stopped.
                    teardown()
                }
            } else {
                teardown()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange:
            guard state == .running, let bridge else { return }
            // The hardware format may have changed (e.g. AirPods → built-in
            // mic). Reinstall the tap against the new format; downstream
            // converters key off each buffer's own format, so they follow.
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let newFormat = input.outputFormat(forBus: 0)
            guard newFormat.sampleRate > 0 else {
                teardown()
                return
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: newFormat) { buffer, _ in
                bridge.yield(buffer)
            }
            if !engine.isRunning {
                try? engine.start()
            }
        default:
            break
        }
    }
}
