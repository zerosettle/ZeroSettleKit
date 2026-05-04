//
//  CheckoutConfigResponse.swift
//  ZeroSettleKit
//
//  Display data for a deferred-mode checkout, fetched from
//  GET /v1/iap/checkout-config/<transaction_id>/.
//
//  No client_secret on this response — that's fetched separately at user-submit
//  time via POST /v1/iap/payment-intents/<transaction_id>/finalize/.
//
//  Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §4.1
//

import Foundation

/// Display data for a deferred-mode checkout config.
///
/// The wire payload carries everything the WebView (or NativePayFlow) needs to
/// initialize Stripe Elements in deferred mode (`mode`, `amount`, `currency`,
/// `paymentMethodConfiguration`) — but **no** `client_secret`. The
/// `client_secret` is materialized later by
/// `Backend.finalizePaymentIntent(transactionId:)` when the user actually
/// submits, which is the anti-spoof primitive: the client never gets a chance
/// to see (and therefore can't tamper with) the amount/currency Stripe will
/// charge.
///
/// No explicit `CodingKeys`: `Backend` configures its `JSONDecoder` with
/// `.convertFromSnakeCase`, which handles the wire-side `product_name` →
/// `productName` mapping automatically. Tests that decode this type directly
/// must use the same key strategy (see `BackendDeferredTests.swift`).
struct CheckoutConfigResponse: Decodable {
    let amount: Int
    let currency: String
    let productName: String
    let isSubscription: Bool
    let hasTrial: Bool
    let trialEnd: Int?
    /// Pre-discount/pre-trial price; used by trial UX to show "then $X/mo"
    /// copy. Equals `amount` for non-trial flows.
    let originalAmountCents: Int
    let publishableKey: String
    let merchantCountry: String?
    let stripeAccount: String?
    let paymentMethodConfiguration: String?
    let subscriptionInterval: String?
}
