//
//  ProductCatalog.swift
//  OmniMind
//
//  Phase 0 scaffold — the full StoreKit 2 subsystem (EntitlementStore,
//  Transaction.updates listener, paywall) lands in Phase 5. Feature gates
//  written before then compile against these types only.
//

import Foundation

/// Single source of truth for product identifiers and the entitlement tier
/// each one unlocks. Mirrored by OmniMind.storekit (local testing) and
/// App Store Connect (production).
nonisolated enum ProductCatalog {
    static let proMonthly = "com.thetpine.workspace.OmniMind.pro.monthly"
    static let proAnnual = "com.thetpine.workspace.OmniMind.pro.annual"

    static let all: Set<String> = [proMonthly, proAnnual]

    /// Free tier: the most recent N meetings stay readable; semantic search
    /// is Pro-only. Capture itself is never gated.
    static let freeMeetingLimit = 3

    /// PILOT MODE: every feature is free while gathering tester feedback
    /// (product decision, 2026-07). The StoreKit subsystem stays built and
    /// tested underneath; flipping this to false re-arms all gates.
    static let pilotUnlockEverything = true

    static func tier(unlockedBy productID: String) -> Tier {
        all.contains(productID) ? .pro : .free
    }
}

/// Entitlement level. Derived exclusively from cryptographically verified
/// StoreKit transactions — never persisted to UserDefaults, never trusted
/// from a local flag.
nonisolated enum Tier: Sendable, Equatable {
    case free
    case pro
}
