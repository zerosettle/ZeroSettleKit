//
//  ZeroSettleForcedJurisdictionTests.swift
//  ZeroSettleKitTests
//

import XCTest
@testable import ZeroSettleKit

@MainActor
final class ZeroSettleForcedJurisdictionTests: XCTestCase {

    override func tearDown() {
        ZeroSettle.shared.forcedJurisdiction = nil
        super.tearDown()
    }

    func testDefaultForcedJurisdictionIsNil() {
        XCTAssertNil(ZeroSettle.shared.forcedJurisdiction)
    }

    func testSetAndReadForcedJurisdiction() {
        ZeroSettle.shared.forcedJurisdiction = .eu
        XCTAssertEqual(ZeroSettle.shared.forcedJurisdiction, .eu)

        ZeroSettle.shared.forcedJurisdiction = .us
        XCTAssertEqual(ZeroSettle.shared.forcedJurisdiction, .us)

        ZeroSettle.shared.forcedJurisdiction = nil
        XCTAssertNil(ZeroSettle.shared.forcedJurisdiction)
    }

    func testEffectiveJurisdictionPrefersForcedOverDetected() {
        ZeroSettle.shared.forcedJurisdiction = .eu
        XCTAssertEqual(ZeroSettle.shared.effectiveJurisdiction, .eu)
    }

    func testEffectiveJurisdictionFallsBackToRowWhenNothingSet() {
        ZeroSettle.shared.forcedJurisdiction = nil
        // detectedJurisdiction is private(set) and likely nil in unit tests;
        // effectiveJurisdiction should fall through to .row.
        XCTAssertEqual(ZeroSettle.shared.effectiveJurisdiction, .row)
    }
}

@MainActor
final class ZSMigrationManagerDeprecatedRegionOverrideTests: XCTestCase {

    override func tearDown() {
        ZeroSettle.shared.forcedJurisdiction = nil
        super.tearDown()
    }

    // Deprecated APIs are still exercised by existing tenant code; verify the
    // wrappers route to the new shared override correctly. Warnings from
    // invoking deprecated APIs are expected and suppressed with @available.

    @available(*, deprecated)
    func testForceUSARegionSetsSharedOverride() {
        ZSMigrationManager.forceUSARegion()
        XCTAssertEqual(ZeroSettle.shared.forcedJurisdiction, .us)
    }

    @available(*, deprecated)
    func testResetRegionOverrideClearsSharedOverride() {
        ZeroSettle.shared.forcedJurisdiction = .us
        ZSMigrationManager.resetRegionOverride()
        XCTAssertNil(ZeroSettle.shared.forcedJurisdiction)
    }

    @available(*, deprecated)
    func testIsUSARegionForcedGetterReflectsSharedOverride() {
        ZeroSettle.shared.forcedJurisdiction = .us
        XCTAssertTrue(ZSMigrationManager.isUSARegionForced)

        ZeroSettle.shared.forcedJurisdiction = .eu
        XCTAssertFalse(ZSMigrationManager.isUSARegionForced)

        ZeroSettle.shared.forcedJurisdiction = nil
        XCTAssertFalse(ZSMigrationManager.isUSARegionForced)
    }

    @available(*, deprecated)
    func testIsUSARegionForcedSetterWritesSharedOverride() {
        ZSMigrationManager.isUSARegionForced = true
        XCTAssertEqual(ZeroSettle.shared.forcedJurisdiction, .us)

        ZSMigrationManager.isUSARegionForced = false
        XCTAssertNil(ZeroSettle.shared.forcedJurisdiction)
    }

    @available(*, deprecated)
    func testIsUSARegionForcedFalseDoesNotClobberNonUSOverride() {
        ZeroSettle.shared.forcedJurisdiction = .eu
        ZSMigrationManager.isUSARegionForced = false  // should be a no-op
        XCTAssertEqual(ZeroSettle.shared.forcedJurisdiction, .eu,
                       "Setting isUSARegionForced = false while a non-US override is active must not clobber it.")
    }
}
