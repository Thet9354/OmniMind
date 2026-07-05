//
//  SearchHit.swift
//  OmniMind
//
//  Sendable retrieval result — the RAG context unit. Carries everything the
//  UI and the Phase 6 synthesis layer need without touching live models.
//

import Foundation

nonisolated struct SearchHit: Sendable, Identifiable, Equatable {
    /// Segment id.
    let id: UUID
    let meetingID: UUID
    let meetingTitle: String
    let text: String
    let startTime: TimeInterval
    let capturedAt: Date
    /// Cosine similarity to the query, in [-1, 1].
    let score: Float
}
