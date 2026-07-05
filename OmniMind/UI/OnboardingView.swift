//
//  OnboardingView.swift
//  OmniMind
//
//  Three screens, three jobs: state the privacy promise, explain the live
//  text layers, and teach mic placement — the single biggest lever on
//  perceived accuracy (pilot finding, 2026-07).
//

import SwiftUI

struct OnboardingView: View {
    let onFinished: () -> Void
    @State private var page = 0

    var body: some View {
        VStack {
            TabView(selection: $page) {
                pageView(
                    icon: "lock.shield.fill",
                    title: "Private by architecture",
                    message: "Everything happens on this iPhone — recording, transcription, search, and AI. Your meetings never touch a server."
                )
                .tag(0)
                pageView(
                    icon: "waveform.badge.mic",
                    title: "Watch words harden",
                    message: "Grey text is the live guess. It settles into black, saved text as you speak — everything black is already safe on your phone."
                )
                .tag(1)
                pageView(
                    icon: "iphone.radiowaves.left.and.right",
                    title: "Placement matters",
                    message: "Put the phone in the middle of the table, screen up. Closer is clearer — distance and mumbling are the mic's worst enemies."
                )
                .tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    onFinished()
                }
            } label: {
                Text(page < 2 ? "Next" : "Start Capturing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .interactiveDismissDisabled()
    }

    private func pageView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .padding(.bottom, 60)
    }
}

#Preview {
    OnboardingView(onFinished: {})
}
