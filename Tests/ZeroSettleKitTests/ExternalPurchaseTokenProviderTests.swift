//
//  ExternalPurchaseTokenProviderTests.swift
//  ZeroSettleKitTests
//
//  Region-gate tests for Apple external-purchase token minting. Only the
//  pure `region(forStorefront:)` gate is unit-testable — the StoreKit
//  ExternalPurchase APIs require app entitlements and cannot run in tests.
//

import XCTest
@testable import ZeroSettleKit

final class ExternalPurchaseTokenProviderTests: XCTestCase {

    func testUsStorefrontMintsNothing() {
        XCTAssertEqual(ExternalPurchaseTokenProvider.region(forStorefront: "USA"), .none)
    }

    func testEuStorefrontIsEU() {
        XCTAssertEqual(ExternalPurchaseTokenProvider.region(forStorefront: "FRA"), .eu)
        XCTAssertEqual(ExternalPurchaseTokenProvider.region(forStorefront: "deu"), .eu)
    }

    func testEeaNonEuIsEU() {
        XCTAssertEqual(ExternalPurchaseTokenProvider.region(forStorefront: "NOR"), .eu)
    }

    func testJapanIsJapan() {
        XCTAssertEqual(ExternalPurchaseTokenProvider.region(forStorefront: "JPN"), .japan)
    }

    func testNilOrUnknownIsNone() {
        XCTAssertEqual(ExternalPurchaseTokenProvider.region(forStorefront: nil), .none)
        // v1: South Korea unsupported (different entitlement + notice-sheet path).
        XCTAssertEqual(ExternalPurchaseTokenProvider.region(forStorefront: "KOR"), .none)
    }
}
