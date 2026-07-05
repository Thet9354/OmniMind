//
//  RecordingView.swift
//  OmniMind
//
//  Live capture screen: finalized segments scroll up, the volatile
//  hypothesis renders once at the bottom in secondary style.
//

import SwiftData
import SwiftUI

struct RecordingView: View {
    @State private var model = RecordingViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                controls
            }
            .navigationTitle("Live Capture")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.attach(container: modelContext.container) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(model.isRecording)
                }
            }
        }
        .interactiveDismissDisabled(model.isRecording)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.segments) { segment in
                        Text(segment.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.volatileText.isEmpty {
                        Text(model.volatileText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .padding()
        .background(.bar)
    }
}

#Preview {
    RecordingView()
}
