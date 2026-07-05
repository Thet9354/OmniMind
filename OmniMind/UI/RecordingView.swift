//
//  RecordingView.swift
//  OmniMind
//
//  Live capture screen: finalized segments scroll up, the volatile
//  hypothesis renders once at the bottom in secondary style.
//

import Speech
import SwiftData
import SwiftUI

struct RecordingView: View {
    @State private var model = RecordingViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Persisted accent/variant choice; non-US English speakers often get
    /// better recognition from their regional model.
    @AppStorage("transcriptionLocale") private var localeIdentifier = "en_US"
    @AppStorage("keepAudio") private var keepAudio = true
    @State private var availableLocales: [Locale] = []
    @State private var autoFollow = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                controls
            }
            .navigationTitle("Live Capture")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                model.attach(container: modelContext.container)
                model.preferredLocaleIdentifier = localeIdentifier
                model.keepAudioEnabled = keepAudio
                // Pay model spin-up NOW, while the user reads the screen —
                // Record then starts in milliseconds.
                model.prewarm()
                let supported = await SpeechTranscriber.supportedLocales
                availableLocales = supported
                    .filter { $0.identifier.hasPrefix("en") }
                    .sorted { $0.identifier < $1.identifier }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: model.isRecording)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    localeMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(model.isRecording)
                }
            }
        }
        .interactiveDismissDisabled(model.isRecording)
    }

    private var localeMenu: some View {
        Menu {
            Toggle("Keep Audio for Replay", isOn: $keepAudio)
                .onChange(of: keepAudio) { _, newValue in
                    model.keepAudioEnabled = newValue
                }
            Divider()
            ForEach(availableLocales, id: \.identifier) { locale in
                Button {
                    localeIdentifier = locale.identifier
                    model.preferredLocaleIdentifier = locale.identifier
                    model.prewarm()   // rebuild the warm analyzer for the new accent
                } label: {
                    if locale.identifier == localeIdentifier {
                        Label(Self.displayName(for: locale), systemImage: "checkmark")
                    } else {
                        Text(Self.displayName(for: locale))
                    }
                }
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .disabled(model.isRecording)
        .accessibilityHint("Capture options: audio retention and accent")
    }

    private static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.liveTail.evictedCount > 0 {
                        Text("Showing the latest \(model.liveTail.elements.count) of \(model.liveTail.totalAppended) segments — everything is saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.liveTail.elements) { segment in
                        Text(segment.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
                    if !model.pendingChunkText.isEmpty {
                        // Finalized speech still accumulating into its chunk.
                        Text(model.pendingChunkText)
                            .foregroundStyle(.primary.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.volatileText.isEmpty {
                        Text(model.volatileText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Transcribing: \(model.volatileText)")
                    }
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding()
                .animation(.easeOut(duration: 0.2), value: model.liveTail.totalAppended)
            }
            // The user scrolling up to reread pauses auto-follow; the Live
            // pill (below) jumps back. No animation on follow scrolls —
            // queued animations make live text feel like it's chasing itself.
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting {
                    autoFollow = false
                }
            }
            .onChange(of: model.volatileText) {
                if autoFollow {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.pendingChunkText) {
                if autoFollow {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoFollow, model.isRecording {
                    Button {
                        autoFollow = true
                        proxy.scrollTo("live-bottom", anchor: .bottom)
                    } label: {
                        Label("Live", systemImage: "arrow.down.circle.fill")
                            .font(.footnote.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding()
                    .accessibilityHint("Resumes following the live transcription")
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if model.isRecording, let startedAt = model.recordingStartedAt {
                HStack(spacing: 12) {
                    LevelMeterView(level: model.audioLevel)
                    Text(startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording in progress")
            }
            if case .failed(let message) = model.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if let warning = model.persistenceWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if model.isDegraded {
                Label(
                    "Audio is backlogged — some audio may be skipped.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityLabel("Warning: audio capture is degraded")
            }
            if model.status == .preparing {
                ProgressView("Preparing on-device model…")
                    .font(.footnote)
            }

            Button {
                model.isRecording ? model.stop() : model.start()
            } label: {
                Label(
                    model.isRecording ? "Stop" : "Record",
                    systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.status == .stopping || model.status == .preparing)
            .accessibilityHint(
                model.isRecording
                    ? "Stops the capture and saves the meeting"
                    : "Starts live on-device transcription"
            )
        }
        .padding()
        .background(.bar)
    }
}

/// Five capsule bars pulsing with input loudness — the app icon, alive.
/// Instant visual proof the app hears you, which makes model latency read
/// as "thinking" instead of "deaf".
private struct LevelMeterView: View {
    let level: Float
    private static let weights: [CGFloat] = [0.35, 0.65, 1.0, 0.65, 0.35]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(
                        width: 4,
                        height: 6 + 24 * Self.weights[index] * CGFloat(level)
                    )
            }
        }
        .frame(height: 32)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

#Preview {
    RecordingView()
}
