//
//  EntitlementStore.swift
//  OmniMind
//
//  StoreKit 2 entitlement subsystem. The ONLY source of truth for premium
//  access is Transaction.currentEntitlements, each element cryptographically
//  verified by StoreKit (JWS signature) — never a local flag, never
//  UserDefaults. Unverified transactions are discarded; revoked ones
//  (refunds, Family Sharing removal) drop the tier on the next refresh.
//

import Foundation
import Observation
import StoreKit

nonisolated enum StoreError: Error, Equatable {
    /// The transaction failed StoreKit's signature verification.
    case unverifiedTransaction
}

@MainActor
@Observable
final class EntitlementStore {
    private(set) var activeTier: Tier = .free
    private(set) var products: [Product] = []
    private var updatesTask: Task<Void, Never>?

    var isPro: Bool { activeTier == .pro }

    /// What feature gates actually read. True for everyone during the
    /// pilot; reverts to entitlement-driven when the pilot flag drops.
    var hasFullAccess: Bool {
        ProductCatalog.pilotUnlockEverything || activeTier == .pro
    }

    // MARK: - Lifecycle

    /// Installs the lifetime Transaction.updates listener and reconciles
    /// current state. Call once, early in app launch — this is what catches
    /// out-of-app events: renewals, Ask-to-Buy approvals, refunds, and
    /// Family Sharing changes that land while the app is backgrounded.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached(priority: .background) { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refreshEntitlements() }
    }

    /// The updates listener is app-lifetime by design; tests that build
    /// short-lived stores call this to avoid leaking listeners.
    func stopListening() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    // MARK: - Entitlements

    /// Recomputes the tier from verified current entitlements only.
    func refreshEntitlements() async {
        var tier = Tier.free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if Self.isEntitling(
                productID: transaction.productID,
                revocationDate: transaction.revocationDate
            ) {
                tier = .pro
            }
        }
        activeTier = tier
    }

    /// Pure entitlement predicate, extracted for direct unit testing.
    nonisolated static func isEntitling(productID: String, revocationDate: Date?) -> Bool {
        revocationDate == nil && ProductCatalog.tier(unlockedBy: productID) == .pro
    }

    // MARK: - Products & purchase

    func loadProducts() async {
        let loaded = (try? await Product.products(for: ProductCatalog.all)) ?? []
        products = loaded.sorted { $0.price < $1.price }
    }

    /// Returns true when the purchase completed and entitlements now
    /// reflect it; false for user-cancel and pending (Ask to Buy).
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw StoreError.unverifiedTransaction
            }
            await refreshEntitlements()
            // Finish AFTER delivering: an unfinished transaction is
            // re-delivered on every launch until finished.
            await transaction.finish()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    /// Explicit restore for edge cases (new device, reinstall).
    /// currentEntitlements already covers the normal path automatically.
    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - Private

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        await refreshEntitlements()
        await transaction.finish()
    }
}
