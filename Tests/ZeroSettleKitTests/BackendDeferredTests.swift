//
//  BackendDeferredTests.swift
//  ZeroSettleKitTests
//
//  Tests for deferred-mode checkout decoding paths added in Task 13:
//    - CheckoutConfigResponse (display data, no client_secret)
//    - The 410 → ZeroSettleError.checkoutConfigExpired mapping in
//      Backend.finalizePaymentIntent is integration-level and lives with
//      Task 16's NativePayFlow tests; we don't have URLProtocol mocking here.
//
//  Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §4.1
//

import XCTest
@testable import ZeroSettleKit

final class BackendDeferredTests: XCTestCase {

    /// Decoder configured identically to `Backend`'s shared decoder: snake-case
    /// key conversion + ISO 8601 dates. `CheckoutConfigResponse` deliberately
    /// has no explicit `CodingKeys`, so production decoding depends on
    /// `.convertFromSnakeCase`; tests must mirror that configuration.
    private var decoder: JSONDecoder!

    override func setUp() {
        super.setUp()
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
    }

    override func tearDown() {
        decoder = nil
        super.tearDown()
    }

    // MARK: - CheckoutConfigResponse

    func testCheckoutConfigResponseDecodesNonSubscription() throws {
        let json = """
        {
          "amount": 199,
          "currency": "usd",
          "product_name": "Premium Coins",
          "is_subscription": false,
          "has_trial": false,
          "trial_end": null,
          "original_amount_cents": 199,
          "publishable_key": "pk_test_x",
          "merchant_country": "US",
          "stripe_account": null,
          "payment_method_configuration": "pmc_abc",
          "subscription_interval": null
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CheckoutConfigResponse.self, from: json)
        XCTAssertEqual(resp.amount, 199)
        XCTAssertEqual(resp.currency, "usd")
        XCTAssertEqual(resp.productName, "Premium Coins")
        XCTAssertFalse(resp.isSubscription)
        XCTAssertFalse(resp.hasTrial)
        XCTAssertNil(resp.trialEnd)
        XCTAssertEqual(resp.originalAmountCents, 199)
        XCTAssertEqual(resp.publishableKey, "pk_test_x")
        XCTAssertEqual(resp.merchantCountry, "US")
        XCTAssertNil(resp.stripeAccount)
        XCTAssertEqual(resp.paymentMethodConfiguration, "pmc_abc")
        XCTAssertNil(resp.subscriptionInterval)
    }

    func testCheckoutConfigResponseDecodesTrialFields() throws {
        let json = """
        {
          "amount": 0,
          "currency": "usd",
          "product_name": "Premium Monthly",
          "is_subscription": true,
          "has_trial": true,
          "trial_end": 1700000000,
          "original_amount_cents": 999,
          "publishable_key": "pk_test_x",
          "merchant_country": "US",
          "stripe_account": "acct_byos",
          "payment_method_configuration": null,
          "subscription_interval": "month"
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CheckoutConfigResponse.self, from: json)
        XCTAssertEqual(resp.amount, 0)
        XCTAssertTrue(resp.isSubscription)
        XCTAssertTrue(resp.hasTrial)
        XCTAssertEqual(resp.trialEnd, 1700000000)
        XCTAssertEqual(resp.originalAmountCents, 999)
        XCTAssertEqual(resp.stripeAccount, "acct_byos")
        XCTAssertNil(resp.paymentMethodConfiguration)
        XCTAssertEqual(resp.subscriptionInterval, "month")
    }

    func testCheckoutConfigResponseDecodesBYOSEUMerchant() throws {
        let json = """
        {
          "amount": 1299,
          "currency": "eur",
          "product_name": "Annual Plan",
          "is_subscription": true,
          "has_trial": false,
          "trial_end": null,
          "original_amount_cents": 1299,
          "publishable_key": "pk_live_y",
          "merchant_country": "FR",
          "stripe_account": "acct_byos_fr",
          "payment_method_configuration": "pmc_eu",
          "subscription_interval": "year"
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CheckoutConfigResponse.self, from: json)
        XCTAssertEqual(resp.productName, "Annual Plan")
        XCTAssertEqual(resp.merchantCountry, "FR")
        XCTAssertEqual(resp.stripeAccount, "acct_byos_fr")
        XCTAssertEqual(resp.subscriptionInterval, "year")
        XCTAssertEqual(resp.paymentMethodConfiguration, "pmc_eu")
    }

    // MARK: - ZeroSettleError.checkoutConfigExpired

    func testCheckoutConfigExpiredHasLocalizedDescription() {
        let error = ZeroSettleError.checkoutConfigExpired
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }

    // MARK: - CheckoutResponse dual-mode discriminator (Task 14)

    /// The deferred-mode response shape: backend returns `deferred_mode: true`
    /// and omits `client_secret`. The SDK must decode this without errors and
    /// expose `clientSecret == nil`, `deferredMode == true`. Caller will then
    /// invoke `Backend.finalizePaymentIntent(transactionId:)` to materialize
    /// the Stripe intent.
    ///
    /// Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §3.1
    func testCheckoutResponseDecodesDeferredShape() throws {
        let json = """
        {
          "transaction_id": "txn_abc123",
          "amount": 199,
          "currency": "usd",
          "product_name": "Coins",
          "callback_url": "https://api.zerosettle.io/checkout/callback?app_id=1&transaction_id=txn_abc123&product_id=com.app.coins",
          "publishable_key": "pk_test_x",
          "checkout_url": "https://api.zerosettle.io/checkout/native/?#transaction_id=txn_abc123",
          "stripe_account": null,
          "merchant_country": "US",
          "is_subscription": false,
          "subscription_interval": null,
          "trial_end": null,
          "pending_amount": null,
          "original_amount": 199,
          "deferred_mode": true
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CheckoutResponse.self, from: json)
        XCTAssertNil(resp.clientSecret)
        XCTAssertEqual(resp.transactionId, "txn_abc123")
        XCTAssertEqual(resp.amount, 199)
        XCTAssertEqual(resp.deferredMode, true)
        // The deferred-mode checkout URL fragment carries the txn id, not a
        // legacy client_secret value.
        XCTAssertTrue(resp.checkoutUrl.hasSuffix("#transaction_id=txn_abc123"))
    }

    /// The legacy fall-through response shape (tenant flag off OR old SDK):
    /// backend returns `deferred_mode: false` AND `client_secret`. The SDK
    /// must decode both fields and confirm the PI immediately, identical to
    /// the pre-Task-14 contract.
    ///
    /// Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §3.1 §4.6
    func testCheckoutResponseDecodesLegacyFallThrough() throws {
        let json = """
        {
          "client_secret": "pi_test_secret_xyz",
          "transaction_id": "txn_abc123",
          "amount": 199,
          "currency": "usd",
          "product_name": "Coins",
          "callback_url": "https://api.zerosettle.io/checkout/callback?app_id=1&transaction_id=txn_abc123&product_id=com.app.coins",
          "publishable_key": "pk_test_x",
          "checkout_url": "https://api.zerosettle.io/checkout/native/?#pi_test_secret_xyz",
          "stripe_account": null,
          "merchant_country": "US",
          "is_subscription": false,
          "subscription_interval": null,
          "trial_end": null,
          "pending_amount": null,
          "original_amount": 199,
          "deferred_mode": false
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CheckoutResponse.self, from: json)
        XCTAssertEqual(resp.clientSecret, "pi_test_secret_xyz")
        XCTAssertEqual(resp.deferredMode, false)
        XCTAssertEqual(resp.transactionId, "txn_abc123")
    }

    /// Pre-Task-14 backend responses don't carry the `deferred_mode` field at
    /// all. The SDK must keep decoding them — `deferredMode` is optional —
    /// and the absent-field case is treated as legacy (`clientSecret` present).
    func testCheckoutResponseDecodesLegacyWithoutDeferredModeField() throws {
        let json = """
        {
          "client_secret": "pi_old_secret",
          "transaction_id": "txn_old",
          "amount": 199,
          "currency": "usd",
          "product_name": "Coins",
          "callback_url": "https://api.zerosettle.io/checkout/callback",
          "publishable_key": "pk_test_x",
          "checkout_url": "https://api.zerosettle.io/checkout/native/?#pi_old_secret",
          "stripe_account": null,
          "merchant_country": "US",
          "is_subscription": false,
          "subscription_interval": null,
          "trial_end": null,
          "pending_amount": null,
          "original_amount": 199
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CheckoutResponse.self, from: json)
        XCTAssertEqual(resp.clientSecret, "pi_old_secret")
        XCTAssertNil(resp.deferredMode)
    }

    /// Batch-result decode: a deferred-mode batch item has `deferred_mode: true`
    /// and no `client_secret`. `asCheckoutResponse()` should still return a
    /// non-nil `CheckoutResponse` (Task 14 relaxed the guard so a missing
    /// client_secret is no longer treated as an error).
    func testBatchResultDecodesAndConvertsDeferredItem() throws {
        let json = """
        {
          "results": [
            {
              "product_id": "com.app.coins",
              "transaction_id": "txn_batch_a",
              "amount": 199,
              "currency": "usd",
              "product_name": "Coins",
              "callback_url": "https://api.zerosettle.io/cb",
              "publishable_key": "pk_test_x",
              "checkout_url": "https://api.zerosettle.io/checkout/native/?#transaction_id=txn_batch_a",
              "deferred_mode": true
            }
          ]
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(BatchCheckoutResponse.self, from: json)
        XCTAssertEqual(resp.results.count, 1)
        let result = resp.results[0]
        XCTAssertNil(result.error)
        XCTAssertEqual(result.deferredMode, true)
        XCTAssertNil(result.clientSecret)
        let converted = result.asCheckoutResponse()
        XCTAssertNotNil(converted)
        XCTAssertNil(converted?.clientSecret)
        XCTAssertEqual(converted?.deferredMode, true)
        XCTAssertEqual(converted?.transactionId, "txn_batch_a")
    }
}
