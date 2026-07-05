//
//  StoreKitTests.swift
//  OmniMindTests
//
//  Phase 5 verification suite, driven by the local OmniMind.storekit
//  configuration through SKTestSession — no network, no sandbox account.
//
//  Structure note: SKTestSession state is PROCESS-GLOBAL. Splitting flows
//  across test functions lets session teardown/reset race the next test's
//  StoreKit queries (observed: products resolve to zero mid-suite). The
//  entire config-driven flow therefore runs as ONE staged lifecycle test
//  over a single session; the entitlement predicate is tested separately
//  as pure logic.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import OmniMind

/// Anchor for Bundle(for:) — Swift Testing suites are structs.
private final class BundleToken {}

// Environment note: storekitd's TESTING MODE is broken in the iOS 26.5
// simulator runtime (SKInternalErrorDomain Code=3 on every session write,
// products never resolve). This suite passes fully on the iOS 26.1
// simulator and on device — run it there.
@Suite("Phase 5 — StoreKit 2 entitlements")
struct StoreKitTests {

    // MARK: - Config-driven lifecycle (one session, staged)

    /// External events (test-session purchases, refunds) propagate to
    /// currentEntitlements asynchronously — poll briefly instead of racing.
    @MainActor
    private func expectTier(
        _ expected: Tier,
        in store: EntitlementStore,
        stage: Comment,
        within seconds: Double = 10
    ) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            await store.refreshEntitlements()
            if store.activeTier == expected { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(store.activeTier == expected, stage)
    }

    @Test("Store lifecycle: fresh → purchase → revoke → external buy → refund",
          .timeLimit(.minutes(5)))
    @MainActor
    func storeLifecycle() async throws {
        // The configuration must load from the TEST BUNDLE: storekitd (a
        // separate daemon) reads the file, and host-Mac paths are outside
        // its sandbox — a raw repo path yields a session that silently
        // knows zero products. The same file is referenced by the shared
        // scheme for Run, so app and tests share one source of truth.
        let url = try #require(
            Bundle(for: BundleToken.self)
                .url(forResource: "OmniMind", withExtension: "storekit"),
            "OmniMind.storekit missing from test bundle"
        )
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()

        // Stage 1 — products resolve from the local configuration.
        // Session activation lands in the StoreKit daemon asynchronously;
        // poll rather than racing it with a single-shot query.
        let store = EntitlementStore()
        let productsDeadline = ContinuousClock.now + .seconds(15)
        while store.products.count < 2, ContinuousClock.now < productsDeadline {
            await store.loadProducts()
            if store.products.count < 2 {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        #expect(store.products.count == 2, "products from local config")
        #expect(Set(store.products.map(\.id)) == ProductCatalog.all)

        // Stage 2 — fresh install is free tier.
        await expectTier(.free, in: store, stage: "fresh install")

        // Stage 3 — in-app purchase unlocks Pro through the verified path.
        let monthly = try #require(
            store.products.first { $0.id == ProductCatalog.proMonthly }
        )
        let completed = try await store.purchase(monthly)
        #expect(completed, "purchase reported success")
        await expectTier(.pro, in: store, stage: "after purchase")

        // Stage 4 — wiping transactions (account-level revocation analog)
        // drops the tier on the next reconciliation.
        session.clearTransactions()
        await expectTier(.free, in: store, stage: "after transaction wipe")

        // Stage 5 — an OUT-OF-APP purchase (family member, redeemed code)
        // is recognized purely from currentEntitlements.
        let external = try await session.buyProduct(
            identifier: ProductCatalog.proAnnual
        )
        await expectTier(.pro, in: store, stage: "after external purchase")

        // Stage 6 — a refund revokes Pro.
        try session.refundTransaction(identifier: UInt(external.id))
        await expectTier(.free, in: store, stage: "after refund")
    }

    // MARK: - Pure entitlement predicate (the verification-adjacent logic)

    @Test("Entitlement predicate: pro products entitle, revoked or unknown do not")
    func entitlementPredicate() {
        #expect(EntitlementStore.isEntitling(
            productID: ProductCatalog.proMonthly, revocationDate: nil
        ))
        #expect(EntitlementStore.isEntitling(
            productID: ProductCatalog.proAnnual, revocationDate: nil
        ))
        // Refunded transaction: still present in entitlements but revoked.
        #expect(!EntitlementStore.isEntitling(
            productID: ProductCatalog.proMonthly, revocationDate: .now
        ))
        // A product we never sold cannot entitle anything.
        #expect(!EntitlementStore.isEntitling(
            productID: "com.attacker.injected.product", revocationDate: nil
        ))
    }
}
