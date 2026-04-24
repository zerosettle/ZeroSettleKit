//
//  ZSOfferManagerDemoModeTests.swift
//  ZeroSettleKitTests
//

import XCTest
@testable import ZeroSettleKit

final class ZSOfferManagerSynthesizeDemoEntitlementTests: XCTestCase {

    @MainActor
    func testReturnsNilWhenPromptIsNil() {
        XCTAssertNil(ZSOfferManager.synthesizeDemoEntitlement(from: nil))
    }

    @MainActor
    func testReturnsNilWhenEligibleProductIdsIsEmpty() {
        let prompt = MigrationPrompt(
            productId: "",
            eligibleProductIds: [],
            discountPercent: 0,
            title: "", message: "", ctaText: ""
        )
        XCTAssertNil(ZSOfferManager.synthesizeDemoEntitlement(from: prompt))
    }

    @MainActor
    func testReturnsEntitlementWithFirstEligibleProduct() {
        let prompt = MigrationPrompt(
            productId: "com.app.pro",
            eligibleProductIds: ["com.app.weekly", "com.app.yearly"],
            discountPercent: 15,
            title: "", message: "", ctaText: ""
        )
        let result = ZSOfferManager.synthesizeDemoEntitlement(from: prompt)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.productId, "com.app.weekly")
        XCTAssertEqual(result?.source, .storeKit)
        XCTAssertTrue(result?.id.hasPrefix("demo-synth-") ?? false)
    }
}

final class ZSOfferManagerPresentDemoGateTests: XCTestCase {

    @MainActor
    func testPresentInDemoModeSetsAlertAndKeepsStateEligible() {
        defer { ZSOfferManager.demoMode = false }

        let manager = ZSOfferManager(userId: "test-user")
        manager._setStateForTesting(.eligible)
        ZSOfferManager.demoMode = true

        manager.present()

        XCTAssertTrue(manager.showDemoModeAlert)
        XCTAssertEqual(manager.state, .eligible)
    }

    @MainActor
    func testPresentOutsideDemoModeTransitionsToPresented() {
        defer { ZSOfferManager.demoMode = false }

        let manager = ZSOfferManager(userId: "test-user")
        manager._setStateForTesting(.eligible)
        ZSOfferManager.demoMode = false

        manager.present()

        XCTAssertFalse(manager.showDemoModeAlert)
        XCTAssertEqual(manager.state, .presented)
    }

    @MainActor
    func testPresentInDemoModeWithNonEligibleStateIsNoop() {
        defer { ZSOfferManager.demoMode = false }

        let manager = ZSOfferManager(userId: "test-user")
        manager._setStateForTesting(.ineligible)
        ZSOfferManager.demoMode = true

        manager.present()

        XCTAssertFalse(manager.showDemoModeAlert)
        XCTAssertEqual(manager.state, .ineligible)
    }
}

final class ZSOfferManagerPreloadCheckoutDemoGateTests: XCTestCase {

    @MainActor
    func testPreloadCheckoutReturnsNilInDemoMode() async {
        defer { ZSOfferManager.demoMode = false }

        let manager = ZSOfferManager(userId: "test-user")
        ZSOfferManager.demoMode = true

        let result = await manager.preloadCheckout(stripeCustomerId: nil)

        XCTAssertNil(result, "preloadCheckout must not initiate checkout in demo mode")
    }

    @MainActor
    func testStartCheckoutReturnsNilInDemoMode() async {
        defer { ZSOfferManager.demoMode = false }

        let manager = ZSOfferManager(userId: "test-user")
        ZSOfferManager.demoMode = true

        let result = await manager.startCheckout(stripeCustomerId: nil)

        XCTAssertNil(result, "startCheckout must not initiate checkout in demo mode")
    }
}
