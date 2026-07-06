//
//  MeetingImportView.swift
//  OmniMind
//
//  Confirmation step for an incoming .omnimind bundle: show what it is,
//  import only on an explicit tap. Nothing is written until the user says
//  so, and a re-import of a meeting already in the library is refused by
//  identity, not by title.
//

import SwiftData
import SwiftUI

/// An opened-and-decoded bundle awaiting the user's decision.
struct PendingMeetingImport: Identifiable {
    let id = UUID()
    let bundle: MeetingBundle
    let audio: Data?
}

struct MeetingImportView: View {
    let pending: PendingMeetingImport

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var state: ImportState = .ready

    enum ImportState: Equatable {
        case ready
        case importing
        case duplicate
        case failed
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Title", value: pending.bundle.title)
                    LabeledContent(
                        "Recorded",
                        value: pending.bundle.startedAt.formatted(
                            date: .abbreviated, time: .shortened
                        )
                    )
                    LabeledContent(
                        "Segments", value: "\(pending.bundle.segments.count)"
                    )
                    LabeledContent(
                        "Audio",
                        value: pending.audio.map {
                            $0.count.formatted(.byteCount(style: .file))
                        } ?? "Not included"
                    )
                    if pending.bundle.summaryText != nil {
                        LabeledContent("Summary", value: "Included")
                    }
                    if let items = pending.bundle.actionItems, !items.isEmpty {
                        LabeledContent("Action items", value: "\(items.count)")
                    }
                } footer: {
                    Text("Importing adds this meeting to your library on this device. It becomes searchable after the next search indexes it.")
                }

                Section {
                    switch state {
                    case .ready:
                        Button {
                            runImport()
                        } label: {
                            Label("Import Meeting", systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets())
                    case .importing:
                        ProgressView("Importing…")
                            .frame(maxWidth: .infinity)
                    case .duplicate:
                        Label(
                            "This meeting is already in your library.",
                            systemImage: "checkmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    case .failed:
                        Label(
                            "The meeting couldn't be imported.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Received Meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(state == .ready || state == .importing ? "Cancel" : "Done") {
                        dismiss()
                    }
                    .disabled(state == .importing)
                }
            }
        }
    }

    private func runImport() {
        state = .importing
        let container = modelContext.container
        let bundle = pending.bundle
        let audio = pending.audio
        Task {
            let store = EmbeddingStore(modelContainer: container)
            do {
                let id = try await store.importMeeting(bundle)
                // Audio lands under the meeting's own identity, exactly as
                // if it had been recorded here — replay just works.
                if let audio {
                    try? AudioArchive.ensureDirectory()
                    try? audio.write(to: AudioArchive.url(for: id), options: .atomic)
                }
                dismiss()
            } catch PersistenceError.meetingAlreadyExists {
                state = .duplicate
            } catch {
                state = .failed
            }
        }
    }
}

#Preview {
    MeetingImportView(pending: PendingMeetingImport(
        bundle: MeetingBundle(
            id: UUID(),
            title: "Q3 Planning",
            startedAt: .now,
            endedAt: .now,
            summaryText: "Summary",
            summaryMethod: "On-device AI",
            cleanedTranscript: nil,
            actionItems: [ExtractedActionItem(task: "Send report", owner: "Ana", due: nil)],
            segments: []
        ),
        audio: nil
    ))
    .modelContainer(try! ModelContainerFactory.make(inMemory: true))
}
