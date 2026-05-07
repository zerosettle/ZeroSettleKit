//
//  ApplePayPreflightGate.swift
//  ZeroSettleKit
//
//  Pure decision helpers that map (isApplePayOnly, availability state, setup
//  behavior) onto checkout-flow outcomes. Two surfaces, one helper:
//
//  - `ApplePayPreflightGate.evaluate(...)` for imperative entry points
//    (CheckoutSheet.present, WebCheckoutFlow, NativePay) — returns proceed
//    or blocked-with-error.
//  - `ApplePayPreflightGate.Outcome.bannerDisplay` for banner UIs
//    (OfferTipView, MigrationTipView) — projects the gate outcome onto a
//    three-way display state.
//
//  Side-effect-free by design — the caller invokes `presentApplePaySetup()`
//  when `openSetupUI` is true. Keeping the side effect at the call site lets
//  each surface choose its ordering relative to dismissing UI / firing
//  completion handlers.
//
//  Spec: docs/superpowers/specs/2026-05-07-apple-pay-setup-behavior-wiring-design.md
//

/// Imperative-surface decision helper. See file header.
enum ApplePayPreflightGate {
    /// Three-way display state for banner-style surfaces. Maps gate outcomes
    /// onto the banner's render decision. Exposed via an extension on
    /// `Outcome` so the banner code reads naturally: `outcome.bannerDisplay`.
    enum BannerDisplay: Equatable {
        /// Normal offer flow — the banner renders its standard CTA.
        case showOfferCTA
        /// Built-in "Set up Apple Pay" CTA — tap should call
        /// `ZeroSettle.shared.presentApplePaySetup()`.
        case showSetupCTA
        /// Banner hides itself — applies to `.unavailable` (any behavior) and to
        /// `.setupRequired + .delegateToApp` (dev handles their own UI).
        case hide
    }

    /// Outcome of a pre-flight check.
    ///
    /// `ZeroSettleError` does not conform to `Equatable` (associated values on
    /// other cases break it), so `Outcome` does not either. Tests pattern-match
    /// instead — both `applePayUnavailable` and `applePaySetupRequired` are
    /// no-associated-value cases and match cleanly.
    enum Outcome {
        case proceed
        case blocked(error: ZeroSettleError, openSetupUI: Bool)
    }

    static func evaluate(
        isApplePayOnly: Bool,
        state: ApplePayAvailability.State,
        behavior: ApplePaySetupBehavior
    ) -> Outcome {
        guard isApplePayOnly else { return .proceed }
        switch state {
        case .ready:
            return .proceed
        case .unavailable:
            return .blocked(error: .applePayUnavailable, openSetupUI: false)
        case .setupRequired:
            return .blocked(
                error: .applePaySetupRequired,
                openSetupUI: behavior == .presentBuiltInUI
            )
        }
    }
}

extension ApplePayPreflightGate.Outcome {
    var bannerDisplay: ApplePayPreflightGate.BannerDisplay {
        switch self {
        case .proceed:
            return .showOfferCTA
        case .blocked(.applePayUnavailable, _):
            return .hide
        case .blocked(.applePaySetupRequired, true):
            return .showSetupCTA
        case .blocked(.applePaySetupRequired, false):
            return .hide
        case .blocked:
            // Future-proof for additional blocked errors; safest default is hide.
            return .hide
        }
    }
}
