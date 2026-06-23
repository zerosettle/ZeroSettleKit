//
//  CheckoutRouteRoutingTests.swift
//  ZeroSettleKitTests
//
//  Coverage for the `checkout_routing` experiment on the CheckoutSheet entry
//  points (.checkoutSheet modifier, CheckoutSheet.present, .webView/.nativePay
//  via purchase()). These paths do NOT go through `purchase()` — they funnel
//  into the `CheckoutSheet` view, whose `.task` consults the per-product
//  routing directive before loading the web sheet.
//
//  Background: the backend emits a per-product `checkout_route: "web" | "store"`
//  directive (ZSProduct.checkoutRoute) and omits `web_price` + returns 403 on
//  web checkout-create for the store cohort. `purchase()` already honored this
//  (it routes to StoreKit before the web path). The CheckoutSheet paths were
//  the gap: a store-cohort user on .checkoutSheet would hit the web 403 hard
//  failure instead of a clean StoreKit fallback.
//
//  The fix: `CheckoutSheet.routeToStoreKitIfNeeded()` consults the shared
//  `ZSProduct.routesToStoreKit` decision (same predicate `purchase()` uses) and
//  is called from the sheet's `.task` BEFORE the web initiate — so a store
//  cohort never hits `Backend.initiateCheckout` (no 403).
//
//  These tests pin two things:
//    1. `ZSProduct.routesToStoreKit` — the single-source-of-truth predicate,
//       across all four checkoutRoute × webPrice combinations.
//    2. `CheckoutSheet.routeToStoreKitIfNeeded()` — that a store-cohort sheet
//       takes the StoreKit branch (returns true → the `.task` returns before
//       reaching the web `initiateCheckout()`), and a web-cohort sheet does
//       not (returns false → the web path proceeds).
//

import XCTest
import SwiftUI
@testable import ZeroSettleKit

@MainActor
final class CheckoutRouteRoutingTests: XCTestCase {

    private let anonKey = "zerosettle.anonymous_session_uuid"

    override func setUp() {
        super.setUp()
        // ZeroSettle.shared is a process-wide singleton; clear identity state
        // from previous tests so currentUserId resolution is deterministic.
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonKey)
    }

    override func tearDown() {
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func usdPrice() -> Price { Price(amountCents: 999, currencyCode: "USD") }

    /// A subscription with explicit checkoutRoute / webPrice for routing tests.
    private func makeSubscription(
        id: String = "com.test.pro_monthly",
        webPrice: Price?,
        checkoutRoute: ZSProduct.CheckoutRoute
    ) -> ZSProduct {
        ZSProduct(
            id: id,
            displayName: "Pro Monthly",
            productDescription: "test",
            type: .autoRenewableSubscription,
            webPrice: webPrice,
            checkoutRoute: checkoutRoute
        )
    }

    // MARK: - ZSProduct.routesToStoreKit predicate (single source of truth)

    /// Web is allowed ONLY when checkoutRoute == .web AND a web price exists.
    /// All three other combinations route to StoreKit. This is the predicate
    /// every checkout entry point consults so they can't diverge.
    func test_routesToStoreKit_webRouteWithPrice_usesWeb() {
        let p = makeSubscription(webPrice: usdPrice(), checkoutRoute: .web)
        XCTAssertFalse(p.routesToStoreKit,
                       "checkout_route=web + webPrice set → web checkout, not StoreKit")
    }

    func test_routesToStoreKit_storeRouteWithPrice_routesToStoreKit() {
        // The checkout_routing experiment OFF cohort: backend says `store` even
        // though a web price may still be present. checkoutRoute is checked
        // INDEPENDENTLY of web_price omission (defense-in-depth) so the SDK
        // doesn't have to trust the backend dropping web_price.
        let p = makeSubscription(webPrice: usdPrice(), checkoutRoute: .store)
        XCTAssertTrue(p.routesToStoreKit,
                      "checkout_route=store must route to StoreKit even when a webPrice is present")
    }

    func test_routesToStoreKit_webRouteNoPrice_routesToStoreKit() {
        // StoreKit-only product (no Stripe mapping): `web` route but nothing to
        // charge on web.
        let p = makeSubscription(webPrice: nil, checkoutRoute: .web)
        XCTAssertTrue(p.routesToStoreKit,
                      "no webPrice → route to StoreKit even when checkout_route=web")
    }

    func test_routesToStoreKit_storeRouteNoPrice_routesToStoreKit() {
        let p = makeSubscription(webPrice: nil, checkoutRoute: .store)
        XCTAssertTrue(p.routesToStoreKit,
                      "store route + no webPrice → route to StoreKit")
    }

    // MARK: - CheckoutSheet.routeToStoreKitIfNeeded (the .task gate)

    /// THE CONTRACT: a store-cohort sheet takes the StoreKit branch. The sheet's
    /// `.task` does `if await routeToStoreKitIfNeeded() { return }` — so a `true`
    /// return structurally guarantees the web `initiateCheckout()` is never
    /// reached (no `Backend.initiateCheckout`, no 403). The StoreKit purchase
    /// itself throws `.notConfigured` in the test runner (no live StoreKit),
    /// which the routing helper catches and delivers via `onComplete` — proving
    /// a result is delivered WITHOUT any web initiate call.
    func test_routeToStoreKitIfNeeded_storeCohort_takesStoreKitBranch() async {
        var captured: Result<CheckoutTransaction, Error>?
        let sheet = CheckoutSheet<EmptyView>(
            product: makeSubscription(webPrice: usdPrice(), checkoutRoute: .store),
            userId: "identified-alice",
            header: { EmptyView() },
            onComplete: { captured = $0 }
        )

        let handled = await sheet.routeToStoreKitIfNeeded()

        XCTAssertTrue(handled,
                      "store cohort must be handled here so the .task returns before the web initiate")
        // A result was delivered without ever calling Backend.initiateCheckout.
        // It's a failure in the runner (no live StoreKit → .notConfigured), but
        // the point is the StoreKit branch ran, not the web one.
        XCTAssertNotNil(captured,
                        "store cohort must deliver a result through onComplete (via the StoreKit branch)")
    }

    /// A StoreKit-only product (web route but no web price) is also handled by
    /// the StoreKit branch — there's no web price to charge.
    func test_routeToStoreKitIfNeeded_noWebPrice_takesStoreKitBranch() async {
        var captured: Result<CheckoutTransaction, Error>?
        let sheet = CheckoutSheet<EmptyView>(
            product: makeSubscription(webPrice: nil, checkoutRoute: .web),
            userId: "identified-alice",
            header: { EmptyView() },
            onComplete: { captured = $0 }
        )

        let handled = await sheet.routeToStoreKitIfNeeded()

        XCTAssertTrue(handled,
                      "a product with no webPrice must route to StoreKit")
        XCTAssertNotNil(captured,
                        "no-webPrice product must deliver a result through the StoreKit branch")
    }

    /// A web-cohort sheet does NOT take the StoreKit branch — the helper returns
    /// false, so the sheet's `.task` proceeds to the web `initiateCheckout()`.
    /// No onComplete fires from the routing helper (the web path owns that).
    func test_routeToStoreKitIfNeeded_webCohort_doesNotRoute() async {
        var captured: Result<CheckoutTransaction, Error>?
        let sheet = CheckoutSheet<EmptyView>(
            product: makeSubscription(webPrice: usdPrice(), checkoutRoute: .web),
            userId: "identified-alice",
            header: { EmptyView() },
            onComplete: { captured = $0 }
        )

        let handled = await sheet.routeToStoreKitIfNeeded()

        XCTAssertFalse(handled,
                       "a web cohort with a web price must NOT route to StoreKit — the web path proceeds")
        XCTAssertNil(captured,
                     "the routing helper must not fire onComplete for a web-cohort product")
    }
}
