//
//  ChatEngine.swift
//  OmniMind
//
//  Conversational RAG over the whole meeting history: every user turn is
//  re-grounded with fresh retrieval, while one LanguageModelSession keeps
//  the conversation's own thread ("what about the deadline I mentioned?"
//  works). All on-device.
//

import Foundation
import FoundationModels

actor ChatEngine {
    struct Reply: Sendable, Equatable {
        let text: String
        /// Meeting titles that grounded this answer, first-hit order.
        let sources: [String]
    }

    private let store: EmbeddingStore
    private var session: LanguageModelSession?
    private let forceUnavailable: Bool

    init(store: EmbeddingStore, forceUnavailable: Bool = false) {
        self.store = store
        self.forceUnavailable = forceUnavailable
    }

    var isAvailable: Bool {
        !forceUnavailable && SystemLanguageModel.default.availability == .available
    }

    /// One conversational turn. nil means the model is unavailable or the
    /// turn failed — the UI reports it; the conversation itself survives.
    func ask(_ question: String) async -> Reply? {
        guard isAvailable else { return nil }

        // Fresh retrieval every turn: follow-up questions shift topic, and
        // stale grounding is how RAG chats start hallucinating.
        try? await store.prepareEmbedder()
        let hits = (try? await store.search(question, topK: 6)) ?? []
        let context = ContextAssembler.assemble(hits: hits, tokenBudget: 900)

        if session == nil {
            session = LanguageModelSession(instructions: """
                You answer questions about the user's own meeting history. \
                Each question comes with excerpts retrieved from their \
                meetings — answer from those excerpts and from earlier turns \
                of this conversation only. If the excerpts don't cover the \
                question, say the meetings don't cover it. Be concise and \
                never invent details.
                """)
        }
        guard let session else { return nil }

        let prompt = context.text.isEmpty
            ? "No relevant meeting excerpts were found.\n\nQuestion: \(question)"
            : "Meeting excerpts:\n\(context.text)\n\nQuestion: \(question)"

        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Reply(text: text, sources: Self.uniqueSourceTitles(from: context.hits))
        } catch {
            // Context overflow or generation failure: drop the session so
            // the NEXT turn starts fresh instead of failing forever.
            self.session = nil
            return nil
        }
    }

    /// First-appearance-ordered unique meeting titles for source chips.
    nonisolated static func uniqueSourceTitles(from hits: [SearchHit]) -> [String] {
        var seen = Set<String>()
        return hits.compactMap { hit in
            seen.insert(hit.meetingTitle).inserted ? hit.meetingTitle : nil
        }
    }
}
