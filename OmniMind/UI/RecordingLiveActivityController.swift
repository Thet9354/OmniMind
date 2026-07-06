//
//  RecordingLiveActivityController.swift
//  OmniMind
//
//  App-side lifecycle for the recording Live Activity. Strictly
//  best-effort: Live Activities can be disabled per-app in Settings, and
//  no failure here may ever affect capture — every call is fire-and-forget.
//
//  Concurrency shape: Activity<T> handles are not Sendable, so no handle
//  is ever stored or moved across an isolation boundary. Each operation
//  runs in a detached task that looks activities up fresh, and tasks are
//  chained so start/update/end apply in call order.
//

import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityController {
    /// Tail of the operation chain — each op awaits its predecessor, so
    /// a fast start→stop can't reorder into stop→start (stranded island).
    private var pipeline: Task<Void, Never>?

    func start(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        enqueue {
            // Anything still live belongs to a crashed session — clear it
            // so the island always reflects exactly one truth.
            await Self.endAll()
            _ = try? Activity.request(
                attributes: RecordingActivityAttributes(),
                content: ActivityContent(
                    state: RecordingActivityAttributes.ContentState(
                        startedAt: startedAt, segmentCount: 0, isDegraded: false
                    ),
                    staleDate: nil
                )
            )
        }
    }

    func update(startedAt: Date, segmentCount: Int, isDegraded: Bool) {
        let state = RecordingActivityAttributes.ContentState(
            startedAt: startedAt, segmentCount: segmentCount, isDegraded: isDegraded
        )
        enqueue {
            for activity in Activity<RecordingActivityAttributes>.activities {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    func end() {
        enqueue {
            await Self.endAll()
        }
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        pipeline = Task.detached(priority: .utility) { [previous = pipeline] in
            await previous?.value
            await operation()
        }
    }

    private nonisolated static func endAll() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
