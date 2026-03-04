//
//  IAPTests.swift
//  ZeroSettleKitTests
//

import XCTest
@testable import ZeroSettleKit

// MARK: - Configuration Tests

final class ConfigurationTests: XCTestCase {
    func testConfigurationDefaults() {
        let config = ZeroSettle.Configuration(publishableKey: "pk_test_abc123")

        XCTAssertEqual(config.publishableKey, "pk_test_abc123")
        XCTAssertTrue(config.syncStoreKitTransactions)
    }

    func testConfigurationCustomValues() {
        let config = ZeroSettle.Configuration(
            publishableKey: "pk_live_xyz",
            syncStoreKitTransactions: false
        )

        XCTAssertEqual(config.publishableKey, "pk_live_xyz")
        XCTAssertFalse(config.syncStoreKitTransactions)
    }
}

// MARK: - Price Tests

final class PriceTests: XCTestCase {
    func testPriceFormattedFromMicros() {
        let price = Price(amountMicros: 9_990_000, currencyCode: "USD")
        XCTAssertEqual(price.amountCents, 999)
        XCTAssertTrue(price.formatted.contains("9.99"))
    }

    func testPriceFormattedFromCents() {
        let price = Price(amountCents: 999, currencyCode: "USD")
        XCTAssertTrue(price.formatted.contains("9.99"))
    }

    func testPriceFormattedWholeNumber() {
        let price = Price(amountCents: 500, currencyCode: "USD")
        XCTAssertTrue(price.formatted.contains("5.00") || price.formatted.contains("5"))
    }

    func testPriceCodableRoundTrip() throws {
        // Price stores cents internally but encodes/decodes as micros on the wire
        let price = Price(amountCents: 499, currencyCode: "EUR")

        let data = try JSONEncoder().encode(price)
        let decoded = try JSONDecoder().decode(Price.self, from: data)

        XCTAssertEqual(decoded.amountCents, 499)
        XCTAssertEqual(decoded.currencyCode, "EUR")
    }

    func testPriceCentsToMicrosRoundTrip() throws {
        // Verify wire format encodes micros
        let price = Price(amountCents: 999, currencyCode: "USD")
        let data = try JSONEncoder().encode(price)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Wire format should contain micros (999 * 10_000 = 9_990_000)
        XCTAssertEqual(json["amountMicros"] as? Int, 9_990_000)
        XCTAssertEqual(json["currencyCode"] as? String, "USD")
    }

    func testPriceMicrosToCtentsConversion() {
        // 4_990_000 micros = 499 cents
        let price = Price(amountMicros: 4_990_000, currencyCode: "EUR")
        XCTAssertEqual(price.amountCents, 499)
    }

    func testPriceMicrosConversionRounding() {
        // Test rounding: 4_995_000 micros = 499.5 → rounds to 500 cents
        let price = Price(amountMicros: 4_995_000, currencyCode: "USD")
        XCTAssertEqual(price.amountCents, 500)
    }

    func testPriceEquatable() {
        let a = Price(amountCents: 100, currencyCode: "USD")
        let b = Price(amountCents: 100, currencyCode: "USD")
        let c = Price(amountCents: 200, currencyCode: "USD")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - Product Tests

final class ProductTests: XCTestCase {
    func testProductCodable() throws {
        let product = Product(
            id: "com.app.premium",
            displayName: "Premium",
            productDescription: "Unlock all features",
            type: .autoRenewableSubscription,
            webPrice: Price(amountCents: 999, currencyCode: "USD"),
            promotion: nil
        )

        let data = try JSONEncoder().encode(product)
        let decoded = try JSONDecoder().decode(Product.self, from: data)

        XCTAssertEqual(decoded.id, "com.app.premium")
        XCTAssertEqual(decoded.displayName, "Premium")
        XCTAssertEqual(decoded.type, .autoRenewableSubscription)
        XCTAssertNil(decoded.promotion)
    }

    func testProductWithPromotion() throws {
        let promotion = Promotion(
            id: "promo_1",
            displayName: "Launch Sale",
            promotionalPrice: Price(amountCents: 499, currencyCode: "USD"),
            expiresAt: nil,
            type: .percentOff
        )
        let product = Product(
            id: "com.app.pro",
            displayName: "Pro",
            productDescription: "Pro tier",
            type: .nonConsumable,
            webPrice: Price(amountCents: 999, currencyCode: "USD"),
            promotion: promotion
        )

        let data = try JSONEncoder().encode(product)
        let decoded = try JSONDecoder().decode(Product.self, from: data)

        XCTAssertNotNil(decoded.promotion)
        XCTAssertEqual(decoded.promotion?.id, "promo_1")
        XCTAssertEqual(decoded.promotion?.type, .percentOff)
    }

    func testProductTypeRawValues() {
        XCTAssertEqual(Product.ProductType.autoRenewableSubscription.rawValue, "auto_renewable_subscription")
        XCTAssertEqual(Product.ProductType.nonRenewingSubscription.rawValue, "non_renewing_subscription")
        XCTAssertEqual(Product.ProductType.consumable.rawValue, "consumable")
        XCTAssertEqual(Product.ProductType.nonConsumable.rawValue, "non_consumable")
    }
}

// MARK: - Entitlement Tests

final class EntitlementTests: XCTestCase {
    func testEntitlementCodable() throws {
        let entitlement = Entitlement(
            id: "ent_123",
            productId: "com.app.premium",
            source: .webCheckout,
            isActive: true,
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            purchasedAt: Date(timeIntervalSince1970: 1690000000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entitlement)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Entitlement.self, from: data)

        XCTAssertEqual(decoded.id, "ent_123")
        XCTAssertEqual(decoded.productId, "com.app.premium")
        XCTAssertEqual(decoded.source, .webCheckout)
        XCTAssertTrue(decoded.isActive)
    }

    func testEntitlementSourceRawValues() {
        XCTAssertEqual(Entitlement.Source.storeKit.rawValue, "store_kit")
        XCTAssertEqual(Entitlement.Source.webCheckout.rawValue, "web_checkout")
    }

    func testEntitlementStatusRoundTrip() throws {
        // Test encoding known statuses
        let statuses: [Entitlement.Status] = [.active, .paused, .expired, .revoked]
        let expectedStrings = ["active", "paused", "expired", "revoked"]

        for (status, expectedString) in zip(statuses, expectedStrings) {
            XCTAssertEqual(status.rawString, expectedString)
        }
    }

    func testEntitlementStatusUnknownPreservesValue() {
        let status = Entitlement.Status(rawString: "new_future_status")
        XCTAssertEqual(status, .unknown("new_future_status"))
        XCTAssertEqual(status.rawString, "new_future_status")
    }

    func testEntitlementStatusDecoding() throws {
        // JSON with known status
        let activeJSON = """
        {"id":"e1","productId":"p1","source":"web_checkout","isActive":true,"status":"active","purchasedAt":"2024-01-01T00:00:00Z"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let active = try decoder.decode(Entitlement.self, from: activeJSON)
        XCTAssertEqual(active.status, .active)

        // JSON with unknown status
        let unknownJSON = """
        {"id":"e2","productId":"p1","source":"web_checkout","isActive":true,"status":"suspended","purchasedAt":"2024-01-01T00:00:00Z"}
        """.data(using: .utf8)!

        let unknown = try decoder.decode(Entitlement.self, from: unknownJSON)
        XCTAssertEqual(unknown.status, .unknown("suspended"))
    }

    func testEntitlementStatusAbsentDefaultsToActive() throws {
        // JSON without status field should default to .active
        let json = """
        {"id":"e3","productId":"p1","source":"web_checkout","isActive":true,"purchasedAt":"2024-01-01T00:00:00Z"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entitlement = try decoder.decode(Entitlement.self, from: json)
        XCTAssertEqual(entitlement.status, .active)
    }

    func testEntitlementIsPaused() {
        let paused = Entitlement(
            id: "e1", productId: "p1", source: .webCheckout,
            isActive: false, status: .paused, purchasedAt: Date()
        )
        XCTAssertTrue(paused.isPaused)

        let active = Entitlement(
            id: "e2", productId: "p1", source: .webCheckout,
            isActive: true, status: .active, purchasedAt: Date()
        )
        XCTAssertFalse(active.isPaused)
    }
}

// MARK: - Transaction Tests

final class TransactionTests: XCTestCase {
    func testTransactionCodable() throws {
        let transaction = CheckoutTransaction(
            id: "txn_abc",
            productId: "com.app.coins_100",
            status: .completed,
            source: .webCheckout,
            purchasedAt: Date(timeIntervalSince1970: 1690000000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transaction)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CheckoutTransaction.self, from: data)

        XCTAssertEqual(decoded.id, "txn_abc")
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.source, .webCheckout)
    }

    func testTransactionStatusRawValues() {
        XCTAssertEqual(CheckoutTransaction.Status.completed.rawValue, "completed")
        XCTAssertEqual(CheckoutTransaction.Status.pending.rawValue, "pending")
        XCTAssertEqual(CheckoutTransaction.Status.failed.rawValue, "failed")
        XCTAssertEqual(CheckoutTransaction.Status.refunded.rawValue, "refunded")
    }
}

// MARK: - Promotion Tests

final class PromotionTests: XCTestCase {
    func testPromotionCodable() throws {
        let promotion = Promotion(
            id: "promo_summer",
            displayName: "Summer Sale",
            promotionalPrice: Price(amountCents: 299, currencyCode: "USD"),
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            type: .fixedAmount
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(promotion)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Promotion.self, from: data)

        XCTAssertEqual(decoded.id, "promo_summer")
        XCTAssertEqual(decoded.type, .fixedAmount)
        XCTAssertNotNil(decoded.expiresAt)
    }

    func testPromotionTypeRawValues() {
        XCTAssertEqual(Promotion.Kind.percentOff.rawValue, "percent_off")
        XCTAssertEqual(Promotion.Kind.fixedAmount.rawValue, "fixed_amount")
        XCTAssertEqual(Promotion.Kind.freeTrial.rawValue, "free_trial")
    }
}

// MARK: - CancelFlow.OfferType Tests

final class CancelFlowOfferTypeTests: XCTestCase {
    func testOfferTypeKnownValues() {
        XCTAssertEqual(CancelFlow.OfferType(rawString: "discount"), .discount)
        XCTAssertEqual(CancelFlow.OfferType(rawString: "free_trial"), .freeTrial)
        XCTAssertEqual(CancelFlow.OfferType(rawString: "free_extension"), .freeExtension)
    }

    func testOfferTypeUnknownPreservesValue() {
        let type = CancelFlow.OfferType(rawString: "loyalty_reward")
        XCTAssertEqual(type, .other("loyalty_reward"))
        XCTAssertEqual(type.rawString, "loyalty_reward")
    }

    func testOfferTypeRoundTrip() throws {
        let types: [CancelFlow.OfferType] = [.discount, .freeTrial, .freeExtension, .other("custom")]
        let expectedStrings = ["discount", "free_trial", "free_extension", "custom"]

        for (type, expected) in zip(types, expectedStrings) {
            XCTAssertEqual(type.rawString, expected)
            XCTAssertEqual(CancelFlow.OfferType(rawString: expected), type)
        }
    }
}

// MARK: - UpgradeOffer.IneligibilityReason Tests

final class IneligibilityReasonTests: XCTestCase {
    func testKnownReasons() {
        XCTAssertEqual(
            UpgradeOffer.IneligibilityReason(rawString: "no_active_subscription"),
            .noActiveSubscription
        )
        XCTAssertEqual(
            UpgradeOffer.IneligibilityReason(rawString: "already_highest_tier"),
            .alreadyHighestTier
        )
    }

    func testUnknownReasonPreservesValue() {
        let reason = UpgradeOffer.IneligibilityReason(rawString: "region_blocked")
        XCTAssertEqual(reason, .other("region_blocked"))
        XCTAssertEqual(reason.rawString, "region_blocked")
    }

    func testReasonRoundTrip() {
        let reasons: [UpgradeOffer.IneligibilityReason] = [
            .noActiveSubscription, .alreadyHighestTier, .other("test")
        ]
        let expectedStrings = ["no_active_subscription", "already_highest_tier", "test"]

        for (reason, expected) in zip(reasons, expectedStrings) {
            XCTAssertEqual(reason.rawString, expected)
            XCTAssertEqual(UpgradeOffer.IneligibilityReason(rawString: expected), reason)
        }
    }
}

// MARK: - WebCheckoutFlow Callback Parsing Tests

@MainActor
final class WebCheckoutFlowTests: XCTestCase {
    private var flow: WebCheckoutFlow!

    override func setUp() {
        super.setUp()
        let backend = Backend(
            baseURL: URL(string: "https://api.zerosettle.io/api/v1")!,
            publishableKey: "pk_test_123"
        )
        flow = WebCheckoutFlow(backend: backend)
    }

    func testHandleCallbackSuccess() {
        let url = URL(string: "https://zerosettle.io/checkout/callback/app_123?transaction_id=txn_abc&product_id=com.app.premium&status=success")!
        let callback = flow.handleCallback(url: url)

        XCTAssertNotNil(callback)
        XCTAssertEqual(callback?.transactionId, "txn_abc")
        XCTAssertEqual(callback?.productId, "com.app.premium")
        XCTAssertTrue(callback?.success ?? false)
    }

    func testHandleCallbackCancelled() {
        let url = URL(string: "https://zerosettle.io/checkout/callback/app_123?transaction_id=txn_def&product_id=com.app.pro&status=cancelled")!
        let callback = flow.handleCallback(url: url)

        XCTAssertNotNil(callback)
        XCTAssertEqual(callback?.transactionId, "txn_def")
        XCTAssertFalse(callback?.success ?? true)
    }

    func testHandleCallbackWrongHost() {
        let url = URL(string: "https://other-site.com/checkout/callback/app_123?transaction_id=txn&product_id=prod&status=success")!
        let callback = flow.handleCallback(url: url)

        XCTAssertNil(callback)
    }

    func testHandleCallbackWrongPath() {
        let url = URL(string: "https://zerosettle.io/other/path?transaction_id=txn&product_id=prod&status=success")!
        let callback = flow.handleCallback(url: url)

        XCTAssertNil(callback)
    }

    func testHandleCallbackMissingParams() {
        let url = URL(string: "https://zerosettle.io/checkout/callback/app_123?transaction_id=txn")!
        let callback = flow.handleCallback(url: url)

        XCTAssertNil(callback)
    }
}

// MARK: - Error Tests

final class ErrorTests: XCTestCase {
    func testErrorDescriptions() {
        let errors: [ZeroSettleError] = [
            .notConfigured,
            .invalidPublishableKey,
            .productNotFound("com.app.test"),
            .checkoutFailed(reason: .productNotFound),
            .transactionVerificationFailed("expired"),
            .invalidCallbackURL,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
