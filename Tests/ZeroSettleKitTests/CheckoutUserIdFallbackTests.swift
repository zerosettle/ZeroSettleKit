//
//  CheckoutUserIdFallbackTests.swift
//  ZeroSettleKitTests
//
//  Regression coverage for the "userId is required for products" symptom on
//  the .checkoutSheet modifier and CheckoutSheet.present(...) paths when the
//  adopter has called `identify(.user(id:))` but doesn't re-thread `userId`
//  through every checkout call.
//
//  Background: prior to this test, the modifier structs and the UIKit static
//  present(...) consumed `userId` raw — never consulting
//  `ZeroSettle.shared.currentUserId`. `purchaseViaStoreKit` already did
//  (ZeroSettle.swift:1862). The asymmetry surfaced the moment the Flutter
//  example migrated to the identify()-then-userId-less API: every checkout
//  failed with `PaymentSheetError.userIdRequired` because nil propagated all
//  the way to CheckoutSheet's validation.
//
//  This test pins the contract: modifier paths honor `currentUserId` when
//  the explicit `userId` is nil.
//

import XCTest
import SwiftUI
@testable import ZeroSettleKit

@MainActor
final class CheckoutUserIdFallbackTests: XCTestCase {

    private let anonKey = "zerosettle.anonymous_session_uuid"

    override func setUp() {
        super.setUp()
        // ZeroSettle.shared is a process-wide singleton; clear identity state
        // from previous tests.
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonKey)
    }

    override func tearDown() {
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonKey)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Minimal subscription product — `validateUserIdIfRequired` only fires
    /// for sub/non-consumable types, so this is the type we need to test.
    private func makeSubscription(id: String = "com.test.pro_monthly") -> ZSProduct {
        ZSProduct(
            id: id,
            displayName: "Pro Monthly",
            productDescription: "test",
            type: .autoRenewableSubscription
        )
    }

    /// Sets currentUserId by calling identify() and tolerating the network
    /// failure (no backend in the test runner). setActiveUserId is invoked
    /// *before* the network call, so currentUserId is populated regardless
    /// of whether the catalog fetch succeeds.
    private func identifyUser(_ id: String) async {
        do { _ = try await ZeroSettle.shared.identify(.user(id: id)) }
        catch { /* expected without configured backend */ }
    }

    // MARK: - CheckoutSheetModifier

    /// Explicit userId always wins, even when identify() has set a different one.
    /// This protects callers who deliberately pass an alternate id.
    func test_modifier_explicit_userId_overrides_identified() async {
        await identifyUser("identified-alice")
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "identified-alice",
                       "precondition: identify() must populate currentUserId")

        let modifier = CheckoutSheetModifier<EmptyView>(
            isPresented: .constant(false),
            product: makeSubscription(),
            userId: "explicit-bob",
            dismissible: true,
            preload: nil,
            header: { EmptyView() },
            onComplete: { _ in }
        )
        XCTAssertEqual(modifier.effectiveUserId, "explicit-bob",
                       "Explicit userId must take precedence over identified user")
    }

    /// THE REGRESSION: nil explicit userId + identified user must resolve to
    /// the identified user. Before this fix, the modifier consumed `userId`
    /// raw and `CheckoutSheet`'s validation threw `userIdRequired`.
    func test_modifier_nil_explicit_falls_back_to_identified_user() async {
        await identifyUser("identified-alice")

        let modifier = CheckoutSheetModifier<EmptyView>(
            isPresented: .constant(false),
            product: makeSubscription(),
            userId: nil,
            dismissible: true,
            preload: nil,
            header: { EmptyView() },
            onComplete: { _ in }
        )
        XCTAssertEqual(modifier.effectiveUserId, "identified-alice",
                       "nil userId must fall back to ZeroSettle.shared.currentUserId")
    }

    /// When neither is set, fallback stays nil. Validation downstream still
    /// throws `userIdRequired` correctly in this case — that's the documented
    /// behavior for adopters who never identify.
    func test_modifier_no_identify_and_nil_explicit_resolves_to_nil() {
        XCTAssertNil(ZeroSettle.shared.currentUserId,
                     "precondition: no identify() called")

        let modifier = CheckoutSheetModifier<EmptyView>(
            isPresented: .constant(false),
            product: makeSubscription(),
            userId: nil,
            dismissible: true,
            preload: nil,
            header: { EmptyView() },
            onComplete: { _ in }
        )
        XCTAssertNil(modifier.effectiveUserId,
                     "nil userId + no identify() must resolve to nil (validation will fire later)")
    }

    // MARK: - CheckoutSheetItemModifier

    /// Parallel coverage for the item-based modifier. Same fallback semantics
    /// as `CheckoutSheetModifier` — a regression in one is almost certainly
    /// a regression in both.
    func test_item_modifier_nil_explicit_falls_back_to_identified_user() async {
        await identifyUser("identified-alice")

        let modifier = CheckoutSheetItemModifier<EmptyView>(
            item: .constant(nil),
            userId: nil,
            dismissible: true,
            preload: nil,
            header: { EmptyView() },
            onPresent: nil,
            onComplete: { _ in }
        )
        XCTAssertEqual(modifier.effectiveUserId, "identified-alice",
                       "Item modifier: nil userId must fall back to currentUserId")
    }

    func test_item_modifier_explicit_userId_overrides_identified() async {
        await identifyUser("identified-alice")

        let modifier = CheckoutSheetItemModifier<EmptyView>(
            item: .constant(nil),
            userId: "explicit-bob",
            dismissible: true,
            preload: nil,
            header: { EmptyView() },
            onPresent: nil,
            onComplete: { _ in }
        )
        XCTAssertEqual(modifier.effectiveUserId, "explicit-bob",
                       "Item modifier: explicit userId must take precedence")
    }

    // MARK: - Live mutation

    /// effectiveUserId is computed, not stored — so an identify() that happens
    /// AFTER the modifier is constructed must still resolve correctly. This
    /// protects the "configure first, identify later" startup pattern that
    /// the Flutter example uses (configure() runs in main.dart's init, identify()
    /// runs after the user picks an identity).
    func test_modifier_picks_up_identify_called_after_construction() async {
        let modifier = CheckoutSheetModifier<EmptyView>(
            isPresented: .constant(false),
            product: makeSubscription(),
            userId: nil,
            dismissible: true,
            preload: nil,
            header: { EmptyView() },
            onComplete: { _ in }
        )
        XCTAssertNil(modifier.effectiveUserId,
                     "precondition: no identify yet")

        await identifyUser("late-alice")

        XCTAssertEqual(modifier.effectiveUserId, "late-alice",
                       "effectiveUserId must re-evaluate against current ZeroSettle.shared.currentUserId on every read")
    }
}
