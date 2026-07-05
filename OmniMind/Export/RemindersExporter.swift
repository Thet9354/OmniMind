//
//  RemindersExporter.swift
//  OmniMind
//
//  One-way handoff of extracted action items into the user's default
//  Reminders list. Access is requested only when the user explicitly asks
//  to export — never at launch, never speculatively.
//

import EventKit
import Foundation

nonisolated enum RemindersExporter {
    enum ExportError: Error {
        case accessDenied
    }

    /// Saves one reminder per action item (single commit). Returns the
    /// number exported.
    @discardableResult
    static func export(
        _ items: [ExtractedActionItem],
        sourceTitle: String
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }

        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw ExportError.accessDenied }

        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.title = item.task
            var notes: [String] = []
            if let owner = item.owner { notes.append("Owner: \(owner)") }
            if let due = item.due { notes.append("Due: \(due)") }
            notes.append("From meeting: \(sourceTitle)")
            reminder.notes = notes.joined(separator: "\n")
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: false)
        }
        try store.commit()
        return items.count
    }
}
