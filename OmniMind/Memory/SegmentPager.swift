//
//  SegmentPager.swift
//  OmniMind
//
//  Windowed segment fetches for the meeting detail view (§5.1): long
//  transcripts render page by page instead of materializing thousands of
//  rows in one relationship walk.
//

import Foundation
import SwiftData

nonisolated enum SegmentPager {
    static let pageSize = 200

    static func page(
        in context: ModelContext,
        meetingID: UUID,
        offset: Int,
        limit: Int = SegmentPager.pageSize
    ) throws -> [Segment] {
        var descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate { $0.meeting?.id == meetingID },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }
}
