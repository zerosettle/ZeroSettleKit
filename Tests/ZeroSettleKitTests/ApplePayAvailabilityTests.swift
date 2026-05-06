//
//  ApplePayAvailabilityTests.swift
//  ZeroSettleKitTests
//
import XCTest
@testable import ZeroSettleKit

@MainActor
final class ApplePayAvailabilityTests: XCTestCase {

    func testInitialStatePublishedImmediately() {
        let mock = MockApplePayAvailability(initialState: .ready)
        XCTAssertEqual(mock.state, .ready)
    }

    func testStateTransitionUnavailableToReady() {
        let mock = MockApplePayAvailability(initialState: .unavailable)
        var observed: [ApplePayAvailability.State] = []
        let cancellable = mock.$state.sink { observed.append($0) }
        defer { cancellable.cancel() }

        mock.simulate(.setupRequired)
        mock.simulate(.ready)

        // Combine emits the current value on subscribe + each subsequent change.
        XCTAssertEqual(observed, [.unavailable, .setupRequired, .ready])
    }

    func testProductionInitDoesNotCrash() {
        // Smoke test: production init touches PKPaymentAuthorizationController
        // and NotificationCenter — must not throw or crash on simulator.
        let svc = ApplePayAvailability()
        // Simulator: canMakePayments() returns false → .unavailable.
        // Real device behavior cannot be unit-tested; this only guards
        // against init-time regressions.
        XCTAssertNotNil(svc.state)
    }
}
