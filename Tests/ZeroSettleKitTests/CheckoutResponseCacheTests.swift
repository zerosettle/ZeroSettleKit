//
//  CheckoutResponseCacheTests.swift
//  ZeroSettleKitTests
//
//  Tests for CheckoutResponseCache TTL alignment with the backend's
//  Transaction.checkout_config_expires_at (30 min) and the variant-fingerprint
//  cache-key busting (issue #3 — QA override cache staleness).
//
//  Per Task 17 of 2026-04-29-deferred-mode-implementation.md.
//
import XCTest
@testable import ZeroSettleKit

final class CheckoutResponseCacheTests: XCTestCase {
    func testCacheTTLIs30Minutes() async {
        // The cache TTL must be 1800 seconds (30 minutes) to align with the
        // backend's Transaction.checkout_config_expires_at (Phase 1 Task 1).
        // Stale configs that survive the in-memory TTL are caught server-side
        // by /finalize/ → 410, and the SDK falls back to a fresh fetch.
        let cache = CheckoutResponseCache.shared
        let ttl = await cache.testTTL  // see Step 3 — small test-only accessor
        XCTAssertEqual(ttl, 1800, "TTL must be 30 minutes (1800s) for deferred-mode alignment")
    }

    func testCacheReturnsNilForUnknownKey() async {
        let cache = CheckoutResponseCache.shared
        await cache.clearAll()
        let result = await cache.get(
            productId: "com.test.nonexistent",
            userId: "u_test",
            publishableKey: "pk_test_x",
            variantFingerprint: "fp_a")
        XCTAssertNil(result)
    }

    func testCacheClearAllRemovesEntries() async {
        let cache = CheckoutResponseCache.shared
        await cache.set(
            productId: "x", userId: nil, publishableKey: "y",
            variantFingerprint: "fp", response: Self.makeResponse(amount: 100))
        await cache.clearAll()
        let result = await cache.get(
            productId: "x", userId: nil, publishableKey: "y", variantFingerprint: "fp")
        XCTAssertNil(result)
    }

    // MARK: - Variant fingerprint (issue #3)

    /// A set/get pair with the SAME fingerprint must hit — the non-experiment
    /// happy path where a product's price/route/trial is stable across fetches.
    func testCacheHitsWhenFingerprintMatches() async {
        let cache = CheckoutResponseCache.shared
        await cache.clearAll()
        let response = Self.makeResponse(amount: 499)
        await cache.set(
            productId: "com.app.pro", userId: "u1", publishableKey: "pk_live",
            variantFingerprint: "web|499:USD|notrial", response: response)

        let hit = await cache.get(
            productId: "com.app.pro", userId: "u1", publishableKey: "pk_live",
            variantFingerprint: "web|499:USD|notrial")
        XCTAssertNotNil(hit, "Same fingerprint must hit the cache")
        XCTAssertEqual(hit?.amount, 499)
    }

    /// A different fingerprint (a QA override changed the resolved price/route/
    /// trial) must MISS even though productId+userId+pk are identical — this is
    /// the cache-bust that prevents serving the stale config until TTL.
    func testCacheBustsWhenFingerprintChanges() async {
        let cache = CheckoutResponseCache.shared
        await cache.clearAll()
        // Cache an entry resolved at the old variant's price.
        await cache.set(
            productId: "com.app.pro", userId: "u1", publishableKey: "pk_live",
            variantFingerprint: "web|499:USD|notrial",
            response: Self.makeResponse(amount: 499))

        // After an override the resolved price is $3.99 → a different fingerprint.
        let miss = await cache.get(
            productId: "com.app.pro", userId: "u1", publishableKey: "pk_live",
            variantFingerprint: "web|399:USD|notrial")
        XCTAssertNil(miss, "A changed variant fingerprint must bust the cached entry")
    }

    /// consume (destructive read) honors the fingerprint the same way get does —
    /// the NativePay pay() path consumes, and a stale-fingerprint consume must
    /// miss so pay() falls through to a fresh initiateCheckout.
    func testConsumeMissesWhenFingerprintChanges() async {
        let cache = CheckoutResponseCache.shared
        await cache.clearAll()
        await cache.set(
            productId: "com.app.pro", userId: nil, publishableKey: "pk_live",
            variantFingerprint: "web|499:USD|notrial",
            response: Self.makeResponse(amount: 499))

        let miss = await cache.consume(
            productId: "com.app.pro", userId: nil, publishableKey: "pk_live",
            variantFingerprint: "store|noprice|notrial")
        XCTAssertNil(miss)

        // The original entry is still present under its own fingerprint.
        let hit = await cache.consume(
            productId: "com.app.pro", userId: nil, publishableKey: "pk_live",
            variantFingerprint: "web|499:USD|notrial")
        XCTAssertNotNil(hit)
    }

    // MARK: - Helpers

    /// Minimal `CheckoutResponse` for cache tests. Uses the @testable internal
    /// memberwise initializer; only the fields the cache reads/returns matter.
    private static func makeResponse(amount: Int) -> CheckoutResponse {
        CheckoutResponse(
            clientSecret: nil,
            transactionId: "txn_test_\(amount)",
            amount: amount,
            currency: "USD",
            productName: "Test Product",
            originalAmount: nil,
            callbackUrl: "https://example.com/cb",
            publishableKey: "pk_live",
            checkoutUrl: "https://example.com/checkout",
            stripeAccount: nil,
            merchantCountry: nil,
            isSubscription: false,
            subscriptionInterval: nil,
            trialEnd: nil,
            pendingAmount: nil,
            deferredMode: true
        )
    }
}
