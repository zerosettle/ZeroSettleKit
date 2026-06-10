//
//  ExternalPurchaseTokenProviderTests.swift
//  ZeroSettleKitTests
//
//  Region-gate and path-planner tests for Apple external-purchase token
//  minting. Only the pure `region(forStorefront:)` gate and
//  `plannedPaths(...)` planner are unit-testable — the StoreKit
//  ExternalPurchase APIs require app entitlements and cannot run in tests.
//

import XCTest
@testable import ZeroSettleKit

final class ExternalPurchaseTokenProviderTests: XCTestCase {

    // MARK: - Region gate

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

    // MARK: - Path planner (interactive gate)

    private func paths(
        region: ExternalPurchaseTokenProvider.MintRegion,
        interactive: Bool,
        customLink: Bool = true,
        japanLinkOut: Bool = false,
        noticeSheet: Bool = true
    ) -> [ExternalPurchaseTokenProvider.MintPath] {
        ExternalPurchaseTokenProvider.plannedPaths(
            region: region,
            interactive: interactive,
            customLinkAvailable: customLink,
            japanLinkOutAvailable: japanLinkOut,
            noticeSheetAvailable: noticeSheet
        )
    }

    func testNonInteractiveNeverPlansNoticeSheet() {
        // BLOCKER guard: a preload/warm-up must never present the
        // disclosure sheet — only the silent custom-link path may run.
        XCTAssertEqual(
            paths(region: .eu, interactive: false),
            [.customLink(tokenTypes: ["ACQUISITION", "SERVICES"])]
        )
        // Silent path unavailable (iOS 17.4–18.0): nothing at all.
        XCTAssertEqual(paths(region: .eu, interactive: false, customLink: false), [])
    }

    func testInteractiveEuPlansNoticeSheetFallbackAfterCustomLink() {
        XCTAssertEqual(
            paths(region: .eu, interactive: true),
            [.customLink(tokenTypes: ["ACQUISITION", "SERVICES"]), .noticeSheet]
        )
    }

    func testInteractiveEuWithoutCustomLinkPlansNoticeSheetOnly() {
        // iOS 17.4–18.0, or app holds only the alternative-payments
        // entitlement path: the notice sheet is the sole token source.
        XCTAssertEqual(paths(region: .eu, interactive: true, customLink: false), [.noticeSheet])
    }

    func testInteractiveEuBelowNoticeSheetFloorPlansCustomLinkOnly() {
        XCTAssertEqual(
            paths(region: .eu, interactive: true, noticeSheet: false),
            [.customLink(tokenTypes: ["ACQUISITION", "SERVICES"])]
        )
    }

    func testJapanRequiresLinkOutAvailability() {
        XCTAssertEqual(paths(region: .japan, interactive: true, japanLinkOut: false), [])
        XCTAssertEqual(
            paths(region: .japan, interactive: true, japanLinkOut: true),
            [.customLink(tokenTypes: ["LINK_OUT"])]
        )
        // Japan never falls back to the notice sheet, interactive or not.
        XCTAssertEqual(
            paths(region: .japan, interactive: true, japanLinkOut: true, noticeSheet: true),
            [.customLink(tokenTypes: ["LINK_OUT"])]
        )
    }

    func testNoneRegionPlansNothing() {
        XCTAssertEqual(paths(region: .none, interactive: true), [])
        XCTAssertEqual(paths(region: .none, interactive: false), [])
    }
}
