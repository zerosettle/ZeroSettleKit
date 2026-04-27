//
//  CheckoutConstants.swift
//  ZeroSettleKit
//
//  Shared constants for checkout callback handling.
//

import Foundation

/// Backend template selector for the checkout page.
///
/// `native` is the WebView-embed template (uses `messageHandlers` JS bridge);
/// `browser` is the standalone Stripe Elements page for Safari / SFSafariViewController.
/// Public so callers of `ZSOfferManager.startCheckout(checkoutMode:)` can specify it.
public enum CheckoutMode: String, Sendable {
    case native
    case browser
}

/// Shared checkout constants used by both `WebCheckoutFlow` and `ZSPaymentSheet`.
internal enum CheckoutConstants {
    /// Universal link hosts accepted for checkout callbacks.
    ///
    /// ZeroSettle uses **universal links only** — no custom URL schemes.
    static let callbackHosts: [String] = {
        var hosts = ["api.zerosettle.io", "zerosettle.io"]
        #if DEBUG
        hosts += ["api.zerosettle.ngrok.app", "landing.zerosettle.ngrok.app"]
        #endif
        return hosts
    }()

    /// Path prefix for checkout callback URLs.
    static let callbackPathPrefix = "/checkout/callback"
}
