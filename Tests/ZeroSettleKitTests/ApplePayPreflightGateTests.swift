//
//  ApplePayPreflightGateTests.swift
//  ZeroSettleKitTests
//
//  Pure-function tests for the Apple Pay pre-flight decision helper.
//  No PassKit, no UI — exercises every (isApplePayOnly, state, behavior)
//  combination plus the `bannerDisplay` projection used by banner views.
//

import XCTest
@testable import ZeroSettleKit

final class ApplePayPreflightGateTests: XCTestCase {

    // MARK: - evaluate(): not Apple-Pay-only → always proceed

    func testEvaluateNotApplePayOnlyReadyProceeds() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: false, state: .ready, behavior: .presentBuiltInUI
        )
        guard case .proceed = outcome else {
            return XCTFail("Expected .proceed, got \(outcome)")
        }
    }

    func testEvaluateNotApplePayOnlySetupRequiredProceeds() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: false, state: .setupRequired, behavior: .delegateToApp
        )
        guard case .proceed = outcome else {
            return XCTFail("Expected .proceed, got \(outcome)")
        }
    }

    func testEvaluateNotApplePayOnlyUnavailableProceeds() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: false, state: .unavailable, behavior: .presentBuiltInUI
        )
        guard case .proceed = outcome else {
            return XCTFail("Expected .proceed, got \(outcome)")
        }
    }

    // MARK: - evaluate(): Apple-Pay-only + ready → proceed

    func testEvaluateApplePayOnlyReadyPresentBuiltInUIProceeds() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: true, state: .ready, behavior: .presentBuiltInUI
        )
        guard case .proceed = outcome else {
            return XCTFail("Expected .proceed, got \(outcome)")
        }
    }

    func testEvaluateApplePayOnlyReadyDelegateToAppProceeds() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: true, state: .ready, behavior: .delegateToApp
        )
        guard case .proceed = outcome else {
            return XCTFail("Expected .proceed, got \(outcome)")
        }
    }

    // MARK: - evaluate(): Apple-Pay-only + unavailable → blocked, no setup UI

    func testEvaluateApplePayOnlyUnavailablePresentBuiltInUIBlocked() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: true, state: .unavailable, behavior: .presentBuiltInUI
        )
        guard case .blocked(.applePayUnavailable, false) = outcome else {
            return XCTFail("Expected .blocked(.applePayUnavailable, false), got \(outcome)")
        }
    }

    func testEvaluateApplePayOnlyUnavailableDelegateToAppBlocked() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: true, state: .unavailable, behavior: .delegateToApp
        )
        guard case .blocked(.applePayUnavailable, false) = outcome else {
            return XCTFail("Expected .blocked(.applePayUnavailable, false), got \(outcome)")
        }
    }

    // MARK: - evaluate(): Apple-Pay-only + setupRequired → blocked, setup UI per behavior

    func testEvaluateApplePayOnlySetupRequiredPresentBuiltInUIBlockedWithSetupUI() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: true, state: .setupRequired, behavior: .presentBuiltInUI
        )
        guard case .blocked(.applePaySetupRequired, true) = outcome else {
            return XCTFail("Expected .blocked(.applePaySetupRequired, true), got \(outcome)")
        }
    }

    func testEvaluateApplePayOnlySetupRequiredDelegateToAppBlockedWithoutSetupUI() {
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: true, state: .setupRequired, behavior: .delegateToApp
        )
        guard case .blocked(.applePaySetupRequired, false) = outcome else {
            return XCTFail("Expected .blocked(.applePaySetupRequired, false), got \(outcome)")
        }
    }

    // MARK: - bannerDisplay projection

    func testBannerDisplayProceedShowsOfferCTA() {
        XCTAssertEqual(
            ApplePayPreflightGate.Outcome.proceed.bannerDisplay,
            .showOfferCTA
        )
    }

    func testBannerDisplayUnavailableHides() {
        let outcome = ApplePayPreflightGate.Outcome.blocked(
            error: .applePayUnavailable, openSetupUI: false
        )
        XCTAssertEqual(outcome.bannerDisplay, .hide)
    }

    func testBannerDisplaySetupRequiredPresentBuiltInUIShowsSetupCTA() {
        let outcome = ApplePayPreflightGate.Outcome.blocked(
            error: .applePaySetupRequired, openSetupUI: true
        )
        XCTAssertEqual(outcome.bannerDisplay, .showSetupCTA)
    }

    func testBannerDisplaySetupRequiredDelegateToAppHides() {
        let outcome = ApplePayPreflightGate.Outcome.blocked(
            error: .applePaySetupRequired, openSetupUI: false
        )
        XCTAssertEqual(outcome.bannerDisplay, .hide)
    }
}
