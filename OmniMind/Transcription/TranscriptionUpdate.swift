//
//  TranscriptionUpdate.swift
//  OmniMind
//
//  The single typed channel out of the transcription actor. Routing is the
//  consumer's job: volatile → one replaceable UI property (§5.1 memory
//  invariant), finalized → persistence. Only `.finalized` carries a
//  TranscriptSegment, so nothing volatile can ever reach the store by
//  construction.
//

nonisolated enum TranscriptionUpdate: Sendable, Equatable {
    /// In-flight hypothesis for the current utterance. Replaces the previous
    /// volatile text wholesale — never accumulate these.
    case volatile(String)
    /// A finalized, immutable segment. The only variant persistence accepts.
    case finalized(TranscriptSegment)
}
