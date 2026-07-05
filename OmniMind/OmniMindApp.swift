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
    /// Owns the lifetime Transaction.updates listener — started before the
    /// first frame so no out-of-app purchase event can slip past launch.
    @State private var entitlements = EntitlementStore()

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
                .task {
                    // When this process hosts unit tests, the tests own the
                    // StoreKit environment (SKTestSession). Touching the
                    // store here would bind the process to the real,
                    // unconfigured App Store before the session activates.
                    guard !Self.isHostingTests else { return }
                    entitlements.start()
                    await entitlements.loadProducts()
                }
        }
        .modelContainer(container)
        .environment(entitlements)
    }

    private static var isHostingTests: Bool {
        // Environment variables are present from process spawn — unlike
        // NSClassFromString checks, this can't race test-bundle injection.
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }
}
