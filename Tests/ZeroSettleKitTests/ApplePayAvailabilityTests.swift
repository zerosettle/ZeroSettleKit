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
        // Initial state must be one of the three known cases. (The exact
        // value varies across simulator iOS versions — older simulators
        // report .unavailable, iOS 26+ simulators may report .ready.)
        let svc = ApplePayAvailability()
        XCTAssertTrue([.ready, .setupRequired, .unavailable].contains(svc.state))
    }

    func testProductionRefreshIsIdempotentForUnchangedState() {
        // Simulator state is stable across calls — refresh() must not
        // emit duplicate published values when nothing has changed.
        let svc = ApplePayAvailability()
        let initial = svc.state
        var emissions: [ApplePayAvailability.State] = []
        let cancellable = svc.$state.sink { emissions.append($0) }
        defer { cancellable.cancel() }

        svc.refresh()
        svc.refresh()
        svc.refresh()

        // One emission for the initial subscribe; the three refresh()
        // calls must not produce additional emissions when state is
        // unchanged. Captured `initial` to stay agnostic to simulator
        // iOS-version differences in Apple Pay availability.
        XCTAssertEqual(emissions, [initial])
    }
}

@MainActor
final class ApplePayErrorTests: XCTestCase {

    func testApplePayUnavailableHasLocalizedDescription() {
        let err = ZeroSettleError.applePayUnavailable
        XCTAssertEqual(
            err.errorDescription,
            "Apple Pay is required for this purchase but is not available on this device."
        )
    }

    func testApplePaySetupRequiredHasLocalizedDescription() {
        let err = ZeroSettleError.applePaySetupRequired
        XCTAssertEqual(
            err.errorDescription,
            "Apple Pay is required for this purchase but no card is set up in Wallet."
        )
    }

    func testZeroSettleHasApplePayAvailabilityAccessor() {
        // Should be stable across calls (single shared instance).
        let a = ZeroSettle.shared.applePayAvailability
        let b = ZeroSettle.shared.applePayAvailability
        XCTAssertTrue(a === b)
    }
}

@MainActor
final class CheckoutSheetApplePayGateTests: XCTestCase {

    // The gate logic is a small pure helper we'll extract — testing
    // through `present(from:)` would require a UIViewController and a
    // full host app, which our test bundle isn't set up for. The
    // helper takes the same signal inputs and returns the error to
    // surface (or nil to proceed).

    func testGateNoConfigProceeds() {
        XCTAssertNil(
            CheckoutSheetApplePayGate.errorIfBlocked(
                isApplePayOnly: false,
                state: .unavailable
            )
        )
    }

    func testGateApplePayOnlyUnavailableReturnsUnavailableError() {
        let result = CheckoutSheetApplePayGate.errorIfBlocked(
            isApplePayOnly: true,
            state: .unavailable
        )
        // ZeroSettleError has non-Equatable associated values on other
        // cases, so it doesn't conform to Equatable. Pattern-match
        // instead — the behavior under test is identical.
        guard case .applePayUnavailable = result else {
            XCTFail("Expected .applePayUnavailable, got \(String(describing: result))")
            return
        }
    }

    func testGateApplePayOnlySetupRequiredReturnsSetupRequiredError() {
        let result = CheckoutSheetApplePayGate.errorIfBlocked(
            isApplePayOnly: true,
            state: .setupRequired
        )
        guard case .applePaySetupRequired = result else {
            XCTFail("Expected .applePaySetupRequired, got \(String(describing: result))")
            return
        }
    }

    func testGateApplePayOnlyReadyProceeds() {
        XCTAssertNil(
            CheckoutSheetApplePayGate.errorIfBlocked(
                isApplePayOnly: true,
                state: .ready
            )
        )
    }
}
