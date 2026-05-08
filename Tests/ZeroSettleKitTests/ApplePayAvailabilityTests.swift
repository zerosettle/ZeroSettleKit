//
//  ApplePayAvailabilityTests.swift
//  ZeroSettleKitTests
//
import XCTest
@testable import ZeroSettleKit

@MainActor
final class ApplePayAvailabilityTests: XCTestCase {

    func testInitialStateMatchesInitialiser() {
        let mock = MockApplePayAvailability(initialState: .ready)
        XCTAssertEqual(mock.state, .ready)
    }

    func testStateTransitionUnavailableToReady() {
        // ApplePayAvailability migrated from @Published to @Observable in 1.3.4 —
        // there's no `$state.sink` to test against anymore. Verify the actual
        // business behavior (`simulate(_:)` mutates `state`) by reading after
        // each call. The Observation framework's tracking is exercised
        // implicitly by SwiftUI consumers; testing `withObservationTracking`
        // directly would re-test framework plumbing, not our logic.
        let mock = MockApplePayAvailability(initialState: .unavailable)
        XCTAssertEqual(mock.state, .unavailable)

        mock.simulate(.setupRequired)
        XCTAssertEqual(mock.state, .setupRequired)

        mock.simulate(.ready)
        XCTAssertEqual(mock.state, .ready)
    }

    func testSimulateIsIdempotentForUnchangedState() {
        // `simulate(_:)` early-returns when the new state equals the current.
        // Pre-1.3.4 (Combine) this was a "no spurious emissions" test;
        // post-@Observable, the equivalent guarantee is "state value never
        // mutates," which subsumes notification-firing — Observation only
        // fires onChange on actual mutation. Same-state calls must leave
        // state untouched.
        let mock = MockApplePayAvailability(initialState: .ready)
        XCTAssertEqual(mock.state, .ready)

        mock.simulate(.ready)
        mock.simulate(.ready)
        mock.simulate(.ready)

        XCTAssertEqual(mock.state, .ready, "Same-state simulate() must not change state.")
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
        // transition `state` when the computed value is unchanged.
        // Captured `before` to stay agnostic to simulator iOS-version
        // differences in Apple Pay availability.
        let svc = ApplePayAvailability()
        let before = svc.state

        svc.refresh()
        svc.refresh()
        svc.refresh()

        XCTAssertEqual(svc.state, before, "Same-state refresh() must not change state.")
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

    func testApplePaySetupRequiredDelegateToAppHasLocalizedDescription() {
        // .delegateToApp mode: SDK has NOT presented Wallet; consumer owns
        // the UX. errorDescription must surface the user-facing message.
        let err = ZeroSettleError.applePaySetupRequired(autoPresentedSetup: false)
        XCTAssertEqual(
            err.errorDescription,
            "Apple Pay is required for this purchase but no card is set up in Wallet."
        )
    }

    func testApplePaySetupRequiredAutoPresentedSetupReturnsNilDescription() {
        // .presentBuiltInUI mode: SDK is opening Wallet for the consumer.
        // errorDescription must return nil so naive consumer code that does
        // `error.localizedDescription` doesn't show competing UI on top of
        // the system Wallet sheet.
        let err = ZeroSettleError.applePaySetupRequired(autoPresentedSetup: true)
        XCTAssertNil(err.errorDescription)
    }

    func testZeroSettleHasApplePayAvailabilityAccessor() {
        // Should be stable across calls (single shared instance).
        let a = ZeroSettle.shared.applePayAvailability
        let b = ZeroSettle.shared.applePayAvailability
        XCTAssertTrue(a === b)
    }
}
