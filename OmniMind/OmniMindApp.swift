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
    /// An incoming .omnimind bundle, decoded and awaiting user confirmation.
    @State private var pendingImport: PendingMeetingImport?
    @State private var showingImportError = false

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
                .onOpenURL { url in
                    handleIncomingFile(url)
                }
                .sheet(item: $pendingImport) { pending in
                    MeetingImportView(pending: pending)
                }
                .alert("Couldn't Open File", isPresented: $showingImportError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("This file isn't a readable OmniMind meeting bundle.")
                }
        }
        .modelContainer(container)
        .environment(entitlements)
    }

    /// AirDrop / Files hand-off entry point. Decode-and-preview only —
    /// nothing touches the library until the user confirms in the sheet.
    private func handleIncomingFile(_ url: URL) {
        guard url.pathExtension.lowercased() == MeetingBundleCodec.fileExtension else {
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? MeetingBundleCodec.decode(data)
        else {
            showingImportError = true
            return
        }
        // Files delivered by-copy land in Documents/Inbox and are ours to
        // clean up; leave anything outside the sandbox alone.
        if url.path.contains("/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        pendingImport = PendingMeetingImport(
            bundle: decoded.bundle, audio: decoded.audio
        )
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
