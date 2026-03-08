//
//  CheckoutConstants.swift
//  ZeroSettleKit
//
//  Shared constants for checkout callback handling.
//

import Foundation

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

    /// Checkout mode sent to the backend to select which checkout page to serve.
    enum CheckoutMode {
        static let native = "native"
        static let browser = "browser"
    }
}
