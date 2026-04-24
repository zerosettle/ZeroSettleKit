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
