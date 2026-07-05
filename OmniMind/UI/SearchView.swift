//
//  SearchView.swift
//  OmniMind
//
//  Semantic search across all meeting history — serverless local RAG
//  retrieval. Meaning-based, not keyword-based: "money planning" finds
//  "budget review".
//

import SwiftData
import SwiftUI

@MainActor
@Observable
final class SearchViewModel {
    enum State: Equatable {
        case idle
        case preparing      // embedding assets downloading
        case searching
        case results
        case failed(String)
    }

    var query = ""
    private(set) var state: State = .idle
    private(set) var hits: [SearchHit] = []
    private(set) var answer: MeetingSynthesizer.Output?
    private(set) var answering = false

    private var store: EmbeddingStore?

    func attach(container: ModelContainer) {
        guard store == nil else { return }
        store = EmbeddingStore(modelContainer: container)
    }

    func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty else { return }
        answer = nil
        do {
            if await !store.isEmbedderReady {
                state = .preparing
                try await store.prepareEmbedder()
                // Repair anything captured before assets were available.
                try await store.backfillEmbeddings()
            }
            state = .searching
            hits = try await store.search(trimmed, topK: 8)
            state = .results
        } catch is EmbeddingError {
            state = .failed("The on-device language model isn't available yet. Check your connection and try again.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Grounded answer over the current hits. No-ops (leaves hits visible)
    /// when Apple Intelligence is unavailable on this hardware.
    func askAI() async {
        guard !hits.isEmpty, !answering else { return }
        answering = true
        defer { answering = false }
        let context = ContextAssembler.assemble(hits: hits)
        answer = await MeetingSynthesizer().answer(question: query, context: context)
    }
}

struct SearchView: View {
    @State private var model = SearchViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle:
                    ContentUnavailableView(
                        "Semantic Search",
                        systemImage: "sparkle.magnifyingglass",
                        description: Text("Search by meaning across every meeting — entirely on this device.")
                    )
                case .preparing:
                    ProgressView("Preparing language model…")
                case .searching:
                    ProgressView("Searching…")
                case .failed(let message):
                    ContentUnavailableView(
                        "Search Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .results:
                    if model.hits.isEmpty {
                        ContentUnavailableView.search(text: model.query)
                    } else {
                        resultsList
                    }
                }
            }
            .navigationTitle("Search")
        }
        .searchable(text: $model.query, prompt: "Ask your meeting history…")
        .onSubmit(of: .search) {
            Task { await model.runSearch() }
        }
        .task { model.attach(container: modelContext.container) }
    }

    private var resultsList: some View {
        List {
            answerSection
            Section("Matches") {
                ForEach(model.hits) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(hit.meetingTitle)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", max(0, hit.score) * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(hit.text)
                            .lineLimit(4)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var answerSection: some View {
        if let answer = model.answer {
            Section("Answer") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(answer.text)
                    Text("Generated on-device from the matches below.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        } else if model.answering {
            Section {
                ProgressView("Thinking on-device…")
            }
        } else if !model.hits.isEmpty {
            Section {
                Button("Ask AI about these results", systemImage: "sparkles") {
                    Task { await model.askAI() }
                }
            }
        }
    }
}

#Preview {
    SearchView()
        .modelContainer(try! ModelContainerFactory.make(inMemory: true))
}
