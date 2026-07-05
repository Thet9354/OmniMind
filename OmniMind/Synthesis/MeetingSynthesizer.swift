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

/// An action item surfaced from a meeting — the Sendable DTO the UI and
/// Reminders export consume.
nonisolated struct ExtractedActionItem: Sendable, Identifiable {
    let id = UUID()
    let task: String
    let owner: String?
    let due: String?
}

/// Constrained-generation schema: the model must produce this shape.
@Generable
nonisolated private struct GeneratedActionItems {
    @Guide(description: "Concrete tasks someone committed to in the meeting. Empty if none were stated.")
    var items: [GeneratedActionItem]
}

@Generable
nonisolated private struct GeneratedActionItem {
    @Guide(description: "The task as a short imperative sentence, faithful to what was said")
    var task: String
    @Guide(description: "The person responsible, only if explicitly stated")
    var owner: String?
    @Guide(description: "The deadline or timeframe, only if explicitly stated")
    var due: String?
}

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

    // MARK: - Auto-title

    /// A ≤8-word meaningful name for the meeting, replacing the timestamp
    /// filename. nil (model unavailable / unusable reply) keeps the default.
    func title(for segments: [TranscriptSegment]) async -> String? {
        guard foundationModelUsable, !segments.isEmpty else { return nil }
        let transcript = ContextAssembler.clip(
            segments.map(\.text).joined(separator: "\n"),
            toTokens: 1_500
        )
        guard let raw = await generate(
            instructions: """
            You name meeting transcripts. Reply with a short descriptive \
            title of at most six words — no quotes, no trailing punctuation, \
            no preamble, nothing but the title.
            """,
            prompt: "Name this meeting:\n\n\(transcript)"
        ) else { return nil }
        return Self.sanitizedTitle(from: raw)
    }

    /// Defensive post-processing: first line only, wrapping quotes and
    /// trailing punctuation stripped, hard word cap.
    nonisolated static func sanitizedTitle(from raw: String) -> String? {
        var text = strippingPreamble(from: raw)
        text = text.components(separatedBy: .newlines).first ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'“”‘’«»`.,:;!?")
        )
        let words = text.split(separator: " ")
        if words.count > 8 {
            text = words.prefix(8).joined(separator: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Action items

    /// Tasks explicitly committed to in the meeting, via constrained
    /// structured generation (@Generable — the model cannot return prose).
    /// nil = model unavailable; empty = genuinely no action items.
    func actionItems(from segments: [TranscriptSegment]) async -> [ExtractedActionItem]? {
        guard foundationModelUsable, !segments.isEmpty else { return nil }
        let transcript = ContextAssembler.clip(
            segments.map(\.text).joined(separator: "\n"),
            toTokens: 3_000
        )
        do {
            let session = LanguageModelSession(instructions: """
                You extract action items from meeting transcripts: concrete \
                tasks that someone actually committed to doing. Only include \
                tasks stated in the transcript — never invent, never pad. \
                An empty list is the correct answer for a meeting with no \
                commitments.
                """)
            let response = try await session.respond(
                to: "Extract the action items from this transcript:\n\n\(transcript)",
                generating: GeneratedActionItems.self
            )
            return response.content.items.map {
                ExtractedActionItem(task: $0.task, owner: $0.owner, due: $0.due)
            }
        } catch {
            return nil
        }
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
            content. Output the repaired transcript text directly, with no \
            preamble, introduction, apology, or commentary of any kind.
            """,
            prompt: "Repair this transcript:\n\n\(transcript)"
        ) else { return nil }
        let stripped = Self.strippingPreamble(from: cleaned)
        guard !stripped.isEmpty else { return nil }
        return Output(text: stripped, method: .foundationModel)
    }

    /// Language models sometimes prefix output with chatter ("I apologize…",
    /// "Here is the repaired transcript:") despite instructions. Drop such
    /// leading lines; never touch anything past the first substantive line.
    nonisolated static func strippingPreamble(from text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let preambleMarkers = [
            "i apologize", "i'm sorry", "here is", "here's", "sure,", "sure!",
            "certainly", "of course", "below is", "the repaired transcript",
            "okay, here",
        ]
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeFirst()
                continue
            }
            let lowered = trimmed.lowercased()
            let isPreamble = preambleMarkers.contains { lowered.hasPrefix($0) }
                && (trimmed.hasSuffix(":") || lowered.contains("transcript"))
            if isPreamble {
                lines.removeFirst()
                continue
            }
            break
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
