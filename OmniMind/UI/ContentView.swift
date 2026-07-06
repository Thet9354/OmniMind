//
//  ContentView.swift
//  OmniMind
//
//  Root shell. Renders from a windowed @Query, never from in-memory
//  accumulations — see the §5.1 memory invariant. Free tier reads the
//  ProCatalog gates: newest N meetings visible, semantic search Pro-only.
//  Capture is never gated.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \Meeting.startedAt, order: .reverse)
    private var meetings: [Meeting]
    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.openURL) private var openURL
    @State private var showingRecorder = false
    @State private var showingSearch = false
    @State private var showingChat = false
    @State private var showingGroups = false
    @State private var showingPaywall = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    private var visibleMeetings: [Meeting] {
        entitlements.hasFullAccess
            ? meetings
            : Array(meetings.prefix(ProductCatalog.freeMeetingLimit))
    }

    private var lockedCount: Int {
        entitlements.hasFullAccess
            ? 0
            : max(0, meetings.count - ProductCatalog.freeMeetingLimit)
    }

    var body: some View {
        NavigationStack {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView(
                        "No Meetings Yet",
                        systemImage: "waveform.badge.mic",
                        description: Text(
                            "Start a capture to see live, on-device transcription here."
                        )
                    )
                } else {
                    meetingList
                }
            }
            .navigationTitle("OmniMind")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Search", systemImage: "sparkle.magnifyingglass") {
                        if entitlements.hasFullAccess {
                            showingSearch = true
                        } else {
                            showingPaywall = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Ask", systemImage: "bubble.left.and.text.bubble.right") {
                        showingChat = true
                    }
                    .accessibilityHint("Chat with your meeting history")
                }
                if GroupsFeature.enabled {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Groups", systemImage: "person.3") {
                            showingGroups = true
                        }
                        .accessibilityHint("Shared meeting libraries for teams, classes, and projects")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Send Feedback", systemImage: "envelope") {
                        if let url = Self.feedbackURL() {
                            openURL(url)
                        }
                    }
                    .accessibilityHint("Emails the developer with your device details prefilled")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Capture", systemImage: "record.circle") {
                        showingRecorder = true
                    }
                }
            }
            .sheet(isPresented: $showingRecorder) {
                RecordingView()
            }
            .sheet(isPresented: $showingSearch) {
                SearchView()
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showingChat) {
                ChatView()
            }
            .sheet(isPresented: $showingGroups) {
                GroupsView()
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasSeenOnboarding },
                set: { hasSeenOnboarding = !$0 }
            )) {
                OnboardingView { hasSeenOnboarding = true }
            }
        }
    }

    private var meetingList: some View {
        List {
            ForEach(visibleMeetings) { meeting in
                NavigationLink {
                    MeetingDetailView(meeting: meeting)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .font(.headline)
                        Text(
                            "\(meeting.startedAt, format: .dateTime) · \(meeting.segments.count) segments"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteMeetings)

            if lockedCount > 0 {
                Button {
                    showingPaywall = true
                } label: {
                    Label(
                        "Unlock \(lockedCount) older meeting\(lockedCount == 1 ? "" : "s")",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Pilot feedback channel: prefilled mail with the context needed to
    /// reproduce reports (app build, OS). No analytics SDK — the feedback
    /// loop respects the same privacy stance as the product.
    private static func feedbackURL() -> URL? {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """


        —
        OmniMind \(version) (\(build)) · iOS \(os)
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "thetpine254@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "OmniMind Pilot Feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    private func deleteMeetings(at offsets: IndexSet) {
        for index in offsets {
            let meeting = visibleMeetings[index]
            AudioArchive.delete(for: meeting.id)      // retained audio goes too
            modelContext.delete(meeting)              // cascade removes segments
        }
        try? modelContext.save()
    }
}

#Preview {
    let container = try! ModelContainerFactory.make(inMemory: true)
    return ContentView()
        .modelContainer(container)
        .environment(EntitlementStore())
}
