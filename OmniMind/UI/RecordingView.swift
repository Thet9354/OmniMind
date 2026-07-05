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
    @State private var availableLocales: [Locale] = []

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
                let supported = await SpeechTranscriber.supportedLocales
                availableLocales = supported
                    .filter { $0.identifier.hasPrefix("en") }
                    .sorted { $0.identifier < $1.identifier }
            }
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
            ForEach(availableLocales, id: \.identifier) { locale in
                Button {
                    localeIdentifier = locale.identifier
                    model.preferredLocaleIdentifier = locale.identifier
                } label: {
                    if locale.identifier == localeIdentifier {
                        Label(Self.displayName(for: locale), systemImage: "checkmark")
                    } else {
                        Text(Self.displayName(for: locale))
                    }
                }
            }
        } label: {
            Label("Accent", systemImage: "globe")
        }
        .disabled(model.isRecording || availableLocales.isEmpty)
        .accessibilityHint("Choose the English variant that best matches the speakers")
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
                    }
                    if !model.pendingChunkText.isEmpty {
                        // Finalized speech still accumulating into its chunk.
                        Text(model.pendingChunkText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.volatileText.isEmpty {
                        Text(model.volatileText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Transcribing: \(model.volatileText)")
                            .id("volatile")
                    }
                }
                .padding()
            }
            .onChange(of: model.volatileText) {
                withAnimation { proxy.scrollTo("volatile", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
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

#Preview {
    RecordingView()
}
