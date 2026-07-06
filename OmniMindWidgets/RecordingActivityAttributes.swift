//
//  RecordingActivityAttributes.swift
//  OmniMindWidgets
//
//  The contract between the app (which starts/updates the Live Activity)
//  and the widget extension (which renders it). Compiled into BOTH
//  targets — ActivityKit matches activities by this type.
//

import ActivityKit
import Foundation

nonisolated struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Anchors the system-rendered elapsed timer.
        var startedAt: Date
        /// Saved (coalesced) segments so far — proof capture is working.
        var segmentCount: Int
        /// Mirrors the in-app degraded-capture banner (§5.2).
        var isDegraded: Bool
    }
}
