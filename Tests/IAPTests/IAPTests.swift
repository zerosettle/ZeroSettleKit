//
//  IAPTests.swift
//  ZeroSettleIAPTests
//

import XCTest
@testable import ZeroSettleIAP

// MARK: - Configuration Tests

final class ConfigurationTests: XCTestCase {
    func testConfigurationDefaults() {
        let config = ZeroSettleIAP.Configuration(publishableKey: "pk_test_abc123")

        XCTAssertEqual(config.publishableKey, "pk_test_abc123")
        XCTAssertEqual(config.environment, .production)
        XCTAssertTrue(config.syncStoreKitTransactions)
    }

    func testConfigurationCustomValues() {
        let config = ZeroSettleIAP.Configuration(
            publishableKey: "pk_live_xyz",
            environment: .development,
            syncStoreKitTransactions: false
        )

        XCTAssertEqual(config.publishableKey, "pk_live_xyz")
        XCTAssertEqual(config.environment, .development)
        XCTAssertFalse(config.syncStoreKitTransactions)
    }

    func testBackendURLDerivedFromEnvironment() {
        let prodConfig = ZeroSettleIAP.Configuration(
            publishableKey: "pk_live_test",
            environment: .production
        )
        XCTAssertEqual(prodConfig.backendURL.host, "zerosettle.io")

        let devConfig = ZeroSettleIAP.Configuration(
            publishableKey: "pk_test_test",
            environment: .development
        )
        XCTAssertEqual(devConfig.backendURL.host, "staging.zerosettle.io")
    }
}

// MARK: - Price Tests

final class PriceTests: XCTestCase {
    func testPriceFormatted() {
        let price = Price(amountMicros: 9_990_000, currencyCode: "USD")
        XCTAssertTrue(price.formatted.contains("9.99"))
    }

    func testPriceFormattedWholeNumber() {
        let price = Price(amountMicros: 5_000_000, currencyCode: "USD")
        XCTAssertTrue(price.formatted.contains("5.00") || price.formatted.contains("5"))
    }

    func testPriceCodable() throws {
        let price = Price(amountMicros: 4_990_000, currencyCode: "EUR")

        let data = try JSONEncoder().encode(price)
        let decoded = try JSONDecoder().decode(Price.self, from: data)

        XCTAssertEqual(decoded.amountMicros, 4_990_000)
        XCTAssertEqual(decoded.currencyCode, "EUR")
    }

    func testPriceEquatable() {
        let a = Price(amountMicros: 1_000_000, currencyCode: "USD")
        let b = Price(amountMicros: 1_000_000, currencyCode: "USD")
        let c = Price(amountMicros: 2_000_000, currencyCode: "USD")

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
            webPrice: Price(amountMicros: 9_990_000, currencyCode: "USD"),
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
            promotionalPrice: Price(amountMicros: 4_990_000, currencyCode: "USD"),
            expiresAt: nil,
            type: .percentOff
        )
        let product = Product(
            id: "com.app.pro",
            displayName: "Pro",
            productDescription: "Pro tier",
            type: .nonConsumable,
            webPrice: Price(amountMicros: 9_990_000, currencyCode: "USD"),
            promotion: promotion
        )

        let data = try JSONEncoder().encode(product)
        let decoded = try JSONDecoder().decode(Product.self, from: data)

        XCTAssertNotNil(decoded.promotion)
        XCTAssertEqual(decoded.promotion?.id, "promo_1")
        XCTAssertEqual(decoded.promotion?.type, .percentOff)
    }

    func testProductTypeRawValues() {
        XCTAssertEqual(ProductType.autoRenewableSubscription.rawValue, "auto_renewable_subscription")
        XCTAssertEqual(ProductType.nonRenewingSubscription.rawValue, "non_renewing_subscription")
        XCTAssertEqual(ProductType.consumable.rawValue, "consumable")
        XCTAssertEqual(ProductType.nonConsumable.rawValue, "non_consumable")
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
        XCTAssertEqual(EntitlementSource.storeKit.rawValue, "store_kit")
        XCTAssertEqual(EntitlementSource.webCheckout.rawValue, "web_checkout")
    }
}

// MARK: - Transaction Tests

final class TransactionTests: XCTestCase {
    func testTransactionCodable() throws {
        let transaction = Transaction(
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
        let decoded = try decoder.decode(Transaction.self, from: data)

        XCTAssertEqual(decoded.id, "txn_abc")
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.source, .webCheckout)
    }

    func testTransactionStatusRawValues() {
        XCTAssertEqual(TransactionStatus.completed.rawValue, "completed")
        XCTAssertEqual(TransactionStatus.pending.rawValue, "pending")
        XCTAssertEqual(TransactionStatus.failed.rawValue, "failed")
        XCTAssertEqual(TransactionStatus.refunded.rawValue, "refunded")
    }
}

// MARK: - Promotion Tests

final class PromotionTests: XCTestCase {
    func testPromotionCodable() throws {
        let promotion = Promotion(
            id: "promo_summer",
            displayName: "Summer Sale",
            promotionalPrice: Price(amountMicros: 2_990_000, currencyCode: "USD"),
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
        XCTAssertEqual(PromotionType.percentOff.rawValue, "percent_off")
        XCTAssertEqual(PromotionType.fixedAmount.rawValue, "fixed_amount")
        XCTAssertEqual(PromotionType.freeTrial.rawValue, "free_trial")
    }
}

// MARK: - WebCheckoutFlow Callback Parsing Tests

final class WebCheckoutFlowTests: XCTestCase {
    private var flow: WebCheckoutFlow!

    override func setUp() {
        super.setUp()
        let backend = Backend(
            baseURL: URL(string: "https://zerosettle.io/api/v1")!,
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
        let errors: [ZeroSettleIAPError] = [
            .notConfigured,
            .invalidPublishableKey,
            .productNotFound("com.app.test"),
            .checkoutSessionFailed("timeout"),
            .transactionVerificationFailed("expired"),
            .invalidCallbackURL,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
