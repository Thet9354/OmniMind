//
//  OmniMindApp.swift
//  OmniMind
//
//  Created by Phoon Thet Pine on 4/7/26.
//

import SwiftUI
import SwiftData

@main
struct OmniMindApp: App {
    /// Built once at launch. A failure here means the persistent store is
    /// unusable, which is unrecoverable for a local-first app — crash early
    /// and loudly rather than limp along with silent data loss.
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainerFactory.make()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
