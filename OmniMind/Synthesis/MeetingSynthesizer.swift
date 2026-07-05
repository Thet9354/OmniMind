//
//  MeetingSynthesizer.swift
//  OmniMind
//
//  On-device generation via the Foundation Models framework, with a hard
//  guarantee of graceful degradation: every path that can fail (model
//  unavailable, guardrail refusal, generation error) lands on the
//  extractive summarizer, never on an empty screen (§5.5-adjacent).
//

import Foundation
import FoundationModels

actor MeetingSynthesizer {
    enum Method: String, Sendable {
        case foundationModel = "On-device AI"
        case extractive = "Key excerpts"
    }

    struct Output: Sendable, Equatable {
        let text: String
        let method: Method
    }

    private let forceExtractive: Bool

    /// - Parameter forceExtractive: test hook — exercises the fallback
    ///   branch deterministically on hardware where the model IS available.
    init(forceExtractive: Bool = false) {
        self.forceExtractive = forceExtractive
    }

    private var foundationModelUsable: Bool {
        !forceExtractive && SystemLanguageModel.default.availability == .available
    }

    // MARK: - Per-meeting summary

    func summarize(_ segments: [EmbeddedSegment]) async -> Output {
        let entries = segments.map { ($0.segment.text, $0.vector) }
        guard !entries.isEmpty else {
            return Output(text: "", method: .extractive)
        }

        if foundationModelUsable {
            let transcript = ContextAssembler.clip(
                segments.map(\.segment.text).joined(separator: "\n"),
                toTokens: 3_000
            )
            if let generated = await generate(
                instructions: """
                You summarize meeting transcripts. Reply with 2 to 4 plain \
                sentences capturing the key topics, decisions, and action \
                items. Use only information from the transcript.
                """,
                prompt: "Summarize this meeting transcript:\n\n\(transcript)"
            ) {
                return Output(text: generated, method: .foundationModel)
            }
        }

        return Output(
            text: ExtractiveSummarizer.summarize(entries: entries),
            method: .extractive
        )
    }

    // MARK: - Transcript cleanup (accent/ASR-garble repair)

    /// Rewrites the raw transcript into readable prose, fixing recognition
    /// garbles — the strongest lever available for accented speech, since
    /// the acoustic model itself is Apple's. Strictly repair-only prompting;
    /// nil when the model is unavailable (the raw transcript stands).
    func cleanTranscript(_ segments: [TranscriptSegment]) async -> Output? {
        guard foundationModelUsable, !segments.isEmpty else { return nil }
        let transcript = ContextAssembler.clip(
            segments.map(\.text).joined(separator: "\n"),
            toTokens: 3_000
        )
        guard let cleaned = await generate(
            instructions: """
            You repair speech-recognition transcripts. Fix misrecognized \
            words, grammar, and punctuation so the text reads naturally, \
            keeping the original meaning, speaker phrasing, and level of \
            detail. Never add information, never summarize, never omit \
            content. Reply with the repaired transcript only.
            """,
            prompt: "Repair this transcript:\n\n\(transcript)"
        ) else { return nil }
        return Output(text: cleaned, method: .foundationModel)
    }

    // MARK: - Grounded Q&A over retrieval results

    /// nil when the foundation model is unavailable or the context is
    /// empty — the UI then shows retrieval hits only, which is still a
    /// complete search experience.
    func answer(question: String, context: AssembledContext) async -> Output? {
        guard foundationModelUsable, !context.text.isEmpty else { return nil }
        guard let generated = await generate(
            instructions: """
            You answer questions using ONLY the provided meeting excerpts. \
            If the excerpts do not contain the answer, say that the meetings \
            don't cover it. Be concise and do not invent details.
            """,
            prompt: "Meeting excerpts:\n\(context.text)\n\nQuestion: \(question)"
        ) else { return nil }
        return Output(text: generated, method: .foundationModel)
    }

    // MARK: - Private

    private func generate(instructions: String, prompt: String) async -> String? {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            // Guardrail refusal, context overflow, model interruption —
            // all deliberately collapse to the extractive/nil path.
            return nil
        }
    }
}
