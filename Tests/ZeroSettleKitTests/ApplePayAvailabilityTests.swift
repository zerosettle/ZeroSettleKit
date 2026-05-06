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
