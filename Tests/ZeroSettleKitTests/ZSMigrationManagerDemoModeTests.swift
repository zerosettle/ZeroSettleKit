//
//  ZSMigrationManagerDemoModeTests.swift
//  ZeroSettleKitTests
//

import XCTest
@testable import ZeroSettleKit

@MainActor
final class ZSMigrationManagerSynthesizeDemoEntitlementTests: XCTestCase {

    func testReturnsNilWhenPromptIsNil() {
        let result = ZSMigrationManager.synthesizeDemoEntitlement(from: nil)
        XCTAssertNil(result)
    }

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
    }

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
