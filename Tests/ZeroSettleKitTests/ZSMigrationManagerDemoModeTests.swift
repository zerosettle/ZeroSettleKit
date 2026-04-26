//
//  ZSMigrationManagerDemoModeTests.swift
//  ZeroSettleKitTests
//

import XCTest
@testable import ZeroSettleKit

final class ZSMigrationManagerSynthesizeDemoEntitlementTests: XCTestCase {

    @MainActor
    func testReturnsNilWhenPromptIsNil() {
        let result = ZSMigrationManager.synthesizeDemoEntitlement(from: nil)
        XCTAssertNil(result)
    }

    @MainActor
    func testReturnsNilWhenEligibleProductIdsIsEmpty() {
        let prompt = MigrationPrompt(
            productId: "",
            eligibleProductIds: [],
            discountPercent: 0,
            title: "", message: "", ctaText: ""
        )
        let result = ZSMigrationManager.synthesizeDemoEntitlement(from: prompt)
        XCTAssertNil(result)
    }

    @MainActor
    func testReturnsEntitlementWithFirstEligibleProduct() {
        let prompt = MigrationPrompt(
            productId: "com.app.pro",
            eligibleProductIds: ["com.app.monthly", "com.app.yearly"],
            discountPercent: 15,
            title: "", message: "", ctaText: ""
        )
        let result = ZSMigrationManager.synthesizeDemoEntitlement(from: prompt)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.productId, "com.app.monthly")
        XCTAssertEqual(result?.source, .storeKit)
        XCTAssertTrue(result?.isActive ?? false)
        XCTAssertEqual(result?.status, .active)
        XCTAssertTrue(result?.willRenew ?? false)
        // Lock the sentinel-id contract so future code keying on the prefix
        // (e.g., analytics exclusion, admin UI filtering) doesn't silently break.
        XCTAssertTrue(result?.id.hasPrefix("demo-synth-") ?? false)
    }

    @MainActor
    func testSynthesizedEntitlementHasPastPurchaseDate() {
        let prompt = MigrationPrompt(
            productId: "com.app.pro",
            eligibleProductIds: ["com.app.monthly"],
            discountPercent: 0,
            title: "", message: "", ctaText: ""
        )
        let result = ZSMigrationManager.synthesizeDemoEntitlement(from: prompt)
        XCTAssertNotNil(result)
        // Synth purchasedAt is 60 days ago so any reasonable min-tenure check
        // (which demo mode also skips, but belt-and-suspenders) passes.
        let daysAgo = Calendar.current.dateComponents([.day], from: result!.purchasedAt, to: Date()).day ?? 0
        XCTAssertGreaterThan(daysAgo, 30)
    }

    @MainActor
    func testSynthesizedEntitlementHasFutureExpiration() {
        let prompt = MigrationPrompt(
            productId: "com.app.pro",
            eligibleProductIds: ["com.app.monthly"],
            discountPercent: 0,
            title: "", message: "", ctaText: ""
        )
        let result = ZSMigrationManager.synthesizeDemoEntitlement(from: prompt)
        XCTAssertNotNil(result?.expiresAt)
        XCTAssertGreaterThan(result!.expiresAt!, Date())
    }
}

final class ZSMigrationManagerPresentDemoGateTests: XCTestCase {

    @MainActor
    func testPresentInDemoModeSetsAlertAndKeepsStateEligible() {
        defer { ZSMigrationManager.demoMode = .off }

        let manager = ZSMigrationManager(userId: "test-user")
        manager._setStateForTesting(.eligible)
        ZSMigrationManager.demoMode = .migration

        manager.present()

        XCTAssertTrue(manager.showDemoModeAlert)
        XCTAssertEqual(manager.state, .eligible)
    }

    @MainActor
    func testPresentOutsideDemoModeTransitionsToPresented() {
        defer { ZSMigrationManager.demoMode = .off }

        let manager = ZSMigrationManager(userId: "test-user")
        manager._setStateForTesting(.eligible)
        ZSMigrationManager.demoMode = .off

        manager.present()

        XCTAssertFalse(manager.showDemoModeAlert)
        XCTAssertEqual(manager.state, .presented)
    }

    @MainActor
    func testPresentInDemoModeWithNonEligibleStateIsNoop() {
        defer { ZSMigrationManager.demoMode = .off }

        let manager = ZSMigrationManager(userId: "test-user")
        manager._setStateForTesting(.ineligible)
        ZSMigrationManager.demoMode = .migration

        manager.present()

        XCTAssertFalse(manager.showDemoModeAlert)
        XCTAssertEqual(manager.state, .ineligible)
    }
}

final class ZSMigrationManagerPreloadCheckoutDemoGateTests: XCTestCase {

    @MainActor
    func testPreloadCheckoutReturnsNilInDemoMode() async {
        defer { ZSMigrationManager.demoMode = .off }

        let manager = ZSMigrationManager(userId: "test-user")
        ZSMigrationManager.demoMode = .migration

        let result = await manager.preloadCheckout(stripeCustomerId: nil)

        XCTAssertNil(result, "preloadCheckout must not initiate checkout in demo mode")
    }

    @MainActor
    func testStartCheckoutReturnsNilInDemoMode() async {
        defer { ZSMigrationManager.demoMode = .off }

        let manager = ZSMigrationManager(userId: "test-user")
        ZSMigrationManager.demoMode = .migration

        let result = await manager.startCheckout(stripeCustomerId: nil)

        XCTAssertNil(result, "startCheckout must not initiate checkout in demo mode")
    }
}
