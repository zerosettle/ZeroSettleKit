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
}
