//
//  PaywallView.swift
//  OmniMind
//
//  Pro upsell. Auto-dismisses the moment a verified entitlement lands —
//  whether from this purchase, a restore, or an out-of-app event caught
//  by the Transaction.updates listener.
//

import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                benefits
                Spacer(minLength: 0)
                productButtons
                footer
            }
            .padding()
            .navigationTitle("OmniMind Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if entitlements.products.isEmpty {
                await entitlements.loadProducts()
            }
        }
        .onChange(of: entitlements.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.filled.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Your entire meeting memory,\nprivate and searchable.")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("infinity", "Unlimited meeting history")
            benefit("sparkle.magnifyingglass", "Semantic search across everything")
            benefit("lock.shield", "Everything stays on your device")
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var productButtons: some View {
        VStack(spacing: 10) {
            if entitlements.products.isEmpty {
                ProgressView("Loading plans…")
            }
            ForEach(entitlements.products, id: \.id) { product in
                Button {
                    buy(product)
                } label: {
                    VStack(spacing: 2) {
                        Text(product.displayName)
                            .font(.headline)
                        Text(price(for: product))
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .disabled(purchasing)
    }

    private var footer: some View {
        Button("Restore Purchases") {
            Task {
                purchasing = true
                await entitlements.restorePurchases()
                purchasing = false
                if !entitlements.isPro {
                    message = "No previous purchase found for this Apple Account."
                }
            }
        }
        .font(.footnote)
    }

    private func price(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else {
            return product.displayPrice
        }
        let unit = period.unit == .year ? String(localized: "year") : String(localized: "month")
        return "\(product.displayPrice) / \(unit)"
    }

    private func buy(_ product: Product) {
        Task {
            purchasing = true
            defer { purchasing = false }
            do {
                let completed = try await entitlements.purchase(product)
                if !completed {
                    message = "Purchase not completed. If this needs approval (Ask to Buy), Pro unlocks automatically once approved."
                }
            } catch {
                message = "Purchase failed. You have not been charged."
            }
        }
    }
}

#Preview {
    PaywallView()
        .environment(EntitlementStore())
}
