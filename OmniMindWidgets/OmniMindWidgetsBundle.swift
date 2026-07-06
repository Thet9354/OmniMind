//
//  OmniMindWidgetsBundle.swift
//  OmniMindWidgets
//
//  The extension ships exactly one thing: the recording Live Activity.
//  (No home-screen widget yet — a placeholder widget in the gallery is
//  worse than none.)
//

import SwiftUI
import WidgetKit

@main
struct OmniMindWidgetsBundle: WidgetBundle {
    var body: some Widget {
        OmniMindWidgetsLiveActivity()
    }
}
