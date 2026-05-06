//
//  ApplePayAvailability.swift
//  ZeroSettleKit
//
//  Native PassKit-backed tri-state for Apple-Pay-only merchant
//  configurations. Drives banner CTA swap and imperative-checkout
//  pre-flight guards.
//
//  Spec: docs/superpowers/specs/2026-05-06-apple-pay-availability-design.md
//

import Combine
import Foundation
import PassKit
#if canImport(UIKit)
import UIKit
#endif
internal import ZeroSettleCore

// MARK: - Provider Protocol

/// Test seam: production code reads `ApplePayAvailability` directly via
/// `ZeroSettle.shared.applePayAvailability`; tests inject a `MockApplePayAvailability`
/// to drive arbitrary state without touching PassKit.
public protocol ApplePayAvailabilityProviding: AnyObject {
    @MainActor var state: ApplePayAvailability.State { get }
    @MainActor var statePublisher: Published<ApplePayAvailability.State>.Publisher { get }
}

// MARK: - Service

/// Observes Apple Pay device capability and wallet card state. Refreshes
/// automatically when the user adds/removes cards in Wallet or when the
/// app returns to foreground (covers the post-`openPaymentSetup` case
/// where `PKPassLibraryDidChangeNotification` may not fire reliably).
@MainActor
public final class ApplePayAvailability: ObservableObject, ApplePayAvailabilityProviding {

    public enum State: Equatable, Sendable {
        /// Device supports Apple Pay AND user has at least one supported card.
        case ready
        /// Device supports Apple Pay but Wallet has no supported cards.
        case setupRequired
        /// Device cannot do Apple Pay (older hardware, simulator, MDM/parental restriction).
        case unavailable
    }

    /// Standard US Stripe network set. Hardcoded for v1; promote to
    /// `CheckoutConfig.applePayNetworks` if international expansion adds
    /// JCB/CUP/Mada/etc.
    static let defaultNetworks: [PKPaymentNetwork] = [.visa, .masterCard, .amex, .discover]

    @Published public private(set) var state: State

    public var statePublisher: Published<State>.Publisher { $state }

    // `nonisolated(unsafe)` because:
    //  - Writes happen only in `subscribe()` from the `@MainActor`-isolated `init`
    //  - Reads happen only in `deinit`, which by definition runs after the
    //    last reference is gone — no concurrent access is possible
    // The compiler can't prove this; the unsafe annotation is the standard
    // escape hatch for the `@MainActor` class + cleanup-in-deinit pattern.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public init() {
        self.state = Self.compute()
        subscribe()
    }

    deinit {
        // NotificationCenter on iOS 9+ retains the token only weakly when
        // returned from `addObserver(forName:object:queue:using:)`; clean up
        // explicitly anyway for symmetry and to match the existing pattern
        // elsewhere in the SDK.
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Public for explicit refresh (e.g., after returning from
    /// `presentApplePaySetup()` if a caller wants to force-recompute
    /// without waiting for the foreground notification).
    public func refresh() {
        let newState = Self.compute()
        guard newState != state else { return }
        let old = state
        state = newState
        log(transition: (from: old, to: newState))
    }

    // MARK: - Internals

    private static func compute() -> State {
        guard PKPaymentAuthorizationController.canMakePayments() else {
            return .unavailable
        }
        if PKPaymentAuthorizationController.canMakePayments(usingNetworks: defaultNetworks) {
            return .ready
        }
        return .setupRequired
    }

    private func subscribe() {
        let center = NotificationCenter.default
        let queue = OperationQueue.main

        observers.append(
            center.addObserver(
                forName: Notification.Name(rawValue: PKPassLibraryNotificationName.PKPassLibraryDidChange.rawValue),
                object: nil,
                queue: queue
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        )

        #if canImport(UIKit)
        observers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: queue) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        )
        #endif
    }

    private func log(transition: (from: State, to: State)) {
        // Logging is gated to Apple-Pay-only mode at the consumer site
        // (banner / present(from:)) — the service itself logs transitions
        // unconditionally so we have telemetry even outside that mode.
        switch transition.to {
        case .unavailable:
            // ZSLogger has no `.warning`; `.info` is sufficient since `.unavailable`
            // is a normal expected state on simulators and older hardware, not a
            // genuine failure. Consumer site (banner / present(from:)) escalates
            // to user-visible feedback when Apple-Pay-only mode is active.
            ZSLogger.info("Apple Pay unavailable; banner will hide if Apple-Pay-only mode is active", category: .checkout)
        case .setupRequired:
            ZSLogger.info("Apple Pay setup required; setup CTA will show if Apple-Pay-only mode is active", category: .checkout)
        case .ready:
            ZSLogger.info("Apple Pay ready (transition from \(transition.from))", category: .checkout)
        }
    }
}

// MARK: - Copy

enum ApplePayCopy {
    static let setupCTA = "Set up Apple Pay"
}

#if DEBUG
// MARK: - Mock

/// Test-only impl that drives state arbitrarily without touching PassKit.
/// Lives in the production target (gated by `#if DEBUG`) so test bundles
/// can `@testable import ZeroSettleKit` it without polluting production
/// binary surface in release builds.
@MainActor
public final class MockApplePayAvailability: ObservableObject, ApplePayAvailabilityProviding {

    @Published public private(set) var state: ApplePayAvailability.State

    public var statePublisher: Published<ApplePayAvailability.State>.Publisher { $state }

    public init(initialState: ApplePayAvailability.State) {
        self.state = initialState
    }

    public func simulate(_ newState: ApplePayAvailability.State) {
        state = newState
    }
}
#endif
