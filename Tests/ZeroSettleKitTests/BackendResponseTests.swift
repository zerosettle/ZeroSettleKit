//
//  BackendResponseTests.swift
//  ZeroSettleKitTests
//
//  Tests for JSON response parsing of Backend API response payloads.
//  Since the HTTP client cannot be mocked easily, these tests verify that
//  the Codable models decode correctly from realistic JSON payloads using
//  the same decoder configuration as Backend (snake_case + ISO 8601 dates).
//

import XCTest
@testable import ZeroSettleKit

// MARK: - Test-Only Response Wrappers

/// Mirrors the private `TransactionHistoryResponse` in Backend.swift.
private struct TransactionHistoryResponse: Decodable {
    let transactions: [CheckoutTransaction]
}

/// Mirrors the private `EntitlementsResponse` in Backend.swift.
private struct EntitlementsResponse: Decodable {
    let entitlements: [Entitlement]
}

/// Mirrors the private `ProductsResponse` in Backend.swift.
/// The `config` field is omitted here since `ProductCatalog` is not Decodable
/// and the config parsing is done manually in Backend. We test product array
/// decoding and config decoding separately.
private struct ProductsResponse: Decodable {
    let products: [ZSProduct]
    let config: ConfigResponse?
}

private struct ConfigResponse: Decodable {
    let checkout: CheckoutConfigResponse
    let migration: MigrationPromptResponse?
}

private struct CheckoutConfigResponse: Decodable {
    let sheetType: String
    let isEnabled: Bool
    let jurisdictions: [String: JurisdictionConfigResponse]?
    let appleMerchantId: String?
}

private struct JurisdictionConfigResponse: Decodable {
    let sheetType: String
    let isEnabled: Bool
}

private struct MigrationPromptResponse: Decodable {
    let shouldShow: Bool
    let productId: String?
    let discountPercent: Int?
    let title: String?
    let message: String?
    let ctaText: String?
}

// MARK: - BackendResponseTests

final class BackendResponseTests: XCTestCase {

    /// Decoder configured identically to Backend.swift:
    /// snake_case key conversion + ISO 8601 dates.
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

    // MARK: - Transaction History Response

    func testTransactionHistoryResponseDecoding() throws {
        let json = """
        {
            "transactions": [
                {
                    "id": "txn_001",
                    "product_id": "com.app.coins_100",
                    "status": "completed",
                    "source": "web_checkout",
                    "purchased_at": "2024-06-15T10:30:00Z",
                    "expires_at": null,
                    "product_name": "100 Gold Coins",
                    "amount_cents": 499,
                    "currency": "usd"
                },
                {
                    "id": "txn_002",
                    "product_id": "com.app.premium_monthly",
                    "status": "completed",
                    "source": "store_kit",
                    "purchased_at": "2024-07-01T00:00:00Z",
                    "expires_at": "2024-08-01T00:00:00Z",
                    "product_name": "Premium Monthly",
                    "amount_cents": 999,
                    "currency": "usd"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(TransactionHistoryResponse.self, from: json)

        XCTAssertEqual(response.transactions.count, 2)

        // First transaction: consumable, web checkout
        let txn1 = response.transactions[0]
        XCTAssertEqual(txn1.id, "txn_001")
        XCTAssertEqual(txn1.productId, "com.app.coins_100")
        XCTAssertEqual(txn1.status, .completed)
        XCTAssertEqual(txn1.source, .webCheckout)
        XCTAssertEqual(txn1.productName, "100 Gold Coins")
        XCTAssertEqual(txn1.amountCents, 499)
        XCTAssertEqual(txn1.currency, "usd")
        XCTAssertNil(txn1.expiresAt)

        // Second transaction: subscription, StoreKit
        let txn2 = response.transactions[1]
        XCTAssertEqual(txn2.id, "txn_002")
        XCTAssertEqual(txn2.productId, "com.app.premium_monthly")
        XCTAssertEqual(txn2.status, .completed)
        XCTAssertEqual(txn2.source, .storeKit)
        XCTAssertEqual(txn2.productName, "Premium Monthly")
        XCTAssertEqual(txn2.amountCents, 999)
        XCTAssertEqual(txn2.currency, "usd")
        XCTAssertNotNil(txn2.expiresAt)
    }

    func testTransactionHistoryResponseEmpty() throws {
        let json = """
        {
            "transactions": []
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(TransactionHistoryResponse.self, from: json)

        XCTAssertEqual(response.transactions.count, 0)
        XCTAssertTrue(response.transactions.isEmpty)
    }

    // MARK: - Entitlement Response

    func testEntitlementResponseDecoding() throws {
        let json = """
        {
            "entitlements": [
                {
                    "id": "ent_abc",
                    "product_id": "com.app.pro_yearly",
                    "source": "web_checkout",
                    "is_active": true,
                    "status": "paused",
                    "paused_at": "2024-08-10T12:00:00Z",
                    "pause_resumes_at": "2024-09-10T12:00:00Z",
                    "expires_at": "2025-06-15T00:00:00Z",
                    "will_renew": false,
                    "is_trial": false,
                    "trial_ends_at": null,
                    "cancelled_at": null,
                    "purchased_at": "2024-06-15T00:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(EntitlementsResponse.self, from: json)

        XCTAssertEqual(response.entitlements.count, 1)

        let ent = response.entitlements[0]
        XCTAssertEqual(ent.id, "ent_abc")
        XCTAssertEqual(ent.productId, "com.app.pro_yearly")
        XCTAssertEqual(ent.source, .webCheckout)
        XCTAssertTrue(ent.isActive)
        XCTAssertEqual(ent.status, .paused)
        XCTAssertTrue(ent.isPaused)
        XCTAssertNotNil(ent.pausedAt)
        XCTAssertNotNil(ent.pauseResumesAt)
        XCTAssertNotNil(ent.expiresAt)
        XCTAssertFalse(ent.willRenew)
        XCTAssertFalse(ent.isTrial)
        XCTAssertNil(ent.trialEndsAt)
        XCTAssertNil(ent.cancelledAt)
    }

    func testEntitlementResponseDecodingWithTrialAndCancellation() throws {
        let json = """
        {
            "entitlements": [
                {
                    "id": "ent_trial",
                    "product_id": "com.app.premium_monthly",
                    "source": "web_checkout",
                    "is_active": true,
                    "status": "active",
                    "will_renew": true,
                    "is_trial": true,
                    "trial_ends_at": "2025-01-15T00:00:00Z",
                    "purchased_at": "2024-12-15T00:00:00Z"
                },
                {
                    "id": "ent_cancelled",
                    "product_id": "com.app.basic_monthly",
                    "source": "store_kit",
                    "is_active": true,
                    "status": "cancelled",
                    "will_renew": false,
                    "is_trial": false,
                    "cancelled_at": "2024-11-20T09:00:00Z",
                    "expires_at": "2024-12-15T00:00:00Z",
                    "purchased_at": "2024-11-15T00:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(EntitlementsResponse.self, from: json)
        XCTAssertEqual(response.entitlements.count, 2)

        // Trial entitlement
        let trial = response.entitlements[0]
        XCTAssertEqual(trial.id, "ent_trial")
        XCTAssertTrue(trial.isTrial)
        XCTAssertNotNil(trial.trialEndsAt)
        XCTAssertTrue(trial.willRenew)
        XCTAssertNil(trial.cancelledAt)
        XCTAssertFalse(trial.isPaused)

        // Cancelled entitlement (still active until period end)
        let cancelled = response.entitlements[1]
        XCTAssertEqual(cancelled.id, "ent_cancelled")
        XCTAssertEqual(cancelled.source, .storeKit)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertTrue(cancelled.isActive)
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertFalse(cancelled.willRenew)
        XCTAssertNotNil(cancelled.cancelledAt)
    }

    // MARK: - Product Catalog Response

    func testProductCatalogResponseDecoding() throws {
        // ZSProduct model uses custom CodingKeys: appStorePrice encodes as "storekitPrice",
        // syncedToAppStoreConnect encodes as "syncedToAsc".
        // Price encodes amount as "amountMicros" on the wire (micros = cents * 10,000).
        let json = """
        {
            "products": [
                {
                    "id": "com.app.premium_monthly",
                    "display_name": "Premium Monthly",
                    "product_description": "Full access for one month",
                    "type": "auto_renewable_subscription",
                    "web_price": {
                        "amount_micros": 6990000,
                        "currency_code": "USD"
                    },
                    "storekit_price": {
                        "amount_micros": 9990000,
                        "currency_code": "USD"
                    },
                    "synced_to_asc": true,
                    "promotion": null
                },
                {
                    "id": "com.app.coins_100",
                    "display_name": "100 Gold Coins",
                    "product_description": "A pile of gold coins",
                    "type": "consumable",
                    "web_price": {
                        "amount_micros": 990000,
                        "currency_code": "USD"
                    },
                    "synced_to_asc": false
                }
            ],
            "config": {
                "checkout": {
                    "sheet_type": "webview",
                    "is_enabled": true,
                    "apple_merchant_id": "merchant.com.app"
                },
                "migration": {
                    "should_show": true,
                    "product_id": "com.app.premium_monthly",
                    "discount_percent": 20,
                    "title": "Save 20% Forever",
                    "message": "Switch to web checkout and save.",
                    "cta_text": "Switch Now"
                }
            }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProductsResponse.self, from: json)

        // Products
        XCTAssertEqual(response.products.count, 2)

        let premium = response.products[0]
        XCTAssertEqual(premium.id, "com.app.premium_monthly")
        XCTAssertEqual(premium.displayName, "Premium Monthly")
        XCTAssertEqual(premium.productDescription, "Full access for one month")
        XCTAssertEqual(premium.type, .autoRenewableSubscription)
        XCTAssertNotNil(premium.webPrice)
        XCTAssertEqual(premium.webPrice?.amountCents, 699)
        XCTAssertEqual(premium.webPrice?.currencyCode, "USD")
        XCTAssertNotNil(premium.appStorePrice)
        XCTAssertEqual(premium.appStorePrice?.amountCents, 999)
        XCTAssertTrue(premium.syncedToAppStoreConnect)
        XCTAssertNil(premium.promotion)

        let coins = response.products[1]
        XCTAssertEqual(coins.id, "com.app.coins_100")
        XCTAssertEqual(coins.type, .consumable)
        XCTAssertNotNil(coins.webPrice)
        XCTAssertEqual(coins.webPrice?.amountCents, 99)
        XCTAssertNil(coins.appStorePrice)
        XCTAssertFalse(coins.syncedToAppStoreConnect)

        // Config
        XCTAssertNotNil(response.config)
        let config = response.config!
        XCTAssertEqual(config.checkout.sheetType, "webview")
        XCTAssertTrue(config.checkout.isEnabled)
        XCTAssertEqual(config.checkout.appleMerchantId, "merchant.com.app")

        // Migration
        XCTAssertNotNil(config.migration)
        let migration = config.migration!
        XCTAssertTrue(migration.shouldShow)
        XCTAssertEqual(migration.productId, "com.app.premium_monthly")
        XCTAssertEqual(migration.discountPercent, 20)
        XCTAssertEqual(migration.title, "Save 20% Forever")
        XCTAssertEqual(migration.message, "Switch to web checkout and save.")
        XCTAssertEqual(migration.ctaText, "Switch Now")
    }

    func testProductCatalogResponseWithoutConfig() throws {
        let json = """
        {
            "products": [
                {
                    "id": "com.app.coins_50",
                    "display_name": "50 Coins",
                    "product_description": "A handful of coins",
                    "type": "consumable",
                    "web_price": {
                        "amount_micros": 490000,
                        "currency_code": "USD"
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProductsResponse.self, from: json)

        XCTAssertEqual(response.products.count, 1)
        XCTAssertEqual(response.products[0].id, "com.app.coins_50")
        XCTAssertEqual(response.products[0].webPrice?.amountCents, 49)
        XCTAssertNil(response.config)
    }

    func testProductCatalogResponseWithJurisdictionOverrides() throws {
        let json = """
        {
            "products": [],
            "config": {
                "checkout": {
                    "sheet_type": "webview",
                    "is_enabled": true,
                    "jurisdictions": {
                        "eu": {
                            "sheet_type": "safari_vc",
                            "is_enabled": false
                        },
                        "us": {
                            "sheet_type": "native_pay",
                            "is_enabled": true
                        }
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProductsResponse.self, from: json)

        XCTAssertNotNil(response.config)
        let checkout = response.config!.checkout
        XCTAssertEqual(checkout.sheetType, "webview")
        XCTAssertTrue(checkout.isEnabled)
        XCTAssertNil(checkout.appleMerchantId)

        XCTAssertNotNil(checkout.jurisdictions)
        let jurisdictions = checkout.jurisdictions!
        XCTAssertEqual(jurisdictions.count, 2)

        let eu = jurisdictions["eu"]
        XCTAssertNotNil(eu)
        XCTAssertEqual(eu?.sheetType, "safari_vc")
        XCTAssertFalse(eu?.isEnabled ?? true)

        let us = jurisdictions["us"]
        XCTAssertNotNil(us)
        XCTAssertEqual(us?.sheetType, "native_pay")
        XCTAssertTrue(us?.isEnabled ?? false)
    }

    // MARK: - CheckoutTransaction Optional Fields

    func testCheckoutTransactionOptionalFieldsMissing() throws {
        // Simulates the older response format where product_name, amount_cents,
        // and currency are not present (e.g., from getTransaction endpoint).
        let json = """
        {
            "id": "txn_legacy",
            "product_id": "com.app.premium",
            "status": "completed",
            "source": "web_checkout",
            "purchased_at": "2024-05-01T08:00:00Z"
        }
        """.data(using: .utf8)!

        let txn = try decoder.decode(CheckoutTransaction.self, from: json)

        XCTAssertEqual(txn.id, "txn_legacy")
        XCTAssertEqual(txn.productId, "com.app.premium")
        XCTAssertEqual(txn.status, .completed)
        XCTAssertEqual(txn.source, .webCheckout)
        XCTAssertNil(txn.productName)
        XCTAssertNil(txn.amountCents)
        XCTAssertNil(txn.currency)
        XCTAssertNil(txn.expiresAt)
    }

    func testCheckoutTransactionOptionalFieldsPresent() throws {
        let json = """
        {
            "id": "txn_full",
            "product_id": "com.app.gems_500",
            "status": "completed",
            "source": "web_checkout",
            "purchased_at": "2024-09-12T14:30:00Z",
            "expires_at": null,
            "product_name": "500 Gems",
            "amount_cents": 1499,
            "currency": "eur"
        }
        """.data(using: .utf8)!

        let txn = try decoder.decode(CheckoutTransaction.self, from: json)

        XCTAssertEqual(txn.id, "txn_full")
        XCTAssertEqual(txn.productId, "com.app.gems_500")
        XCTAssertEqual(txn.status, .completed)
        XCTAssertEqual(txn.source, .webCheckout)
        XCTAssertEqual(txn.productName, "500 Gems")
        XCTAssertEqual(txn.amountCents, 1499)
        XCTAssertEqual(txn.currency, "eur")
        XCTAssertNil(txn.expiresAt)
    }

    func testCheckoutTransactionWithExpiresAt() throws {
        let json = """
        {
            "id": "txn_sub",
            "product_id": "com.app.pro_monthly",
            "status": "completed",
            "source": "store_kit",
            "purchased_at": "2024-10-01T00:00:00Z",
            "expires_at": "2024-11-01T00:00:00Z",
            "product_name": "Pro Monthly",
            "amount_cents": 999,
            "currency": "usd"
        }
        """.data(using: .utf8)!

        let txn = try decoder.decode(CheckoutTransaction.self, from: json)

        XCTAssertNotNil(txn.expiresAt)
        XCTAssertEqual(txn.source, .storeKit)
        XCTAssertEqual(txn.amountCents, 999)
    }

    // MARK: - Transaction Status Variants

    func testCheckoutTransactionAllStatuses() throws {
        let statuses: [(String, CheckoutTransaction.Status)] = [
            ("pending", .pending),
            ("processing", .processing),
            ("completed", .completed),
            ("failed", .failed),
            ("refunded", .refunded),
        ]

        for (rawValue, expectedStatus) in statuses {
            let json = """
            {
                "id": "txn_status_\(rawValue)",
                "product_id": "com.app.test",
                "status": "\(rawValue)",
                "source": "web_checkout",
                "purchased_at": "2024-01-01T00:00:00Z"
            }
            """.data(using: .utf8)!

            let txn = try decoder.decode(CheckoutTransaction.self, from: json)
            XCTAssertEqual(txn.status, expectedStatus, "Expected status \(expectedStatus) for raw value '\(rawValue)'")
        }
    }

    // MARK: - Entitlement Defaults for Optional Fields

    func testEntitlementDecodingWithMinimalFields() throws {
        // Backend may omit optional fields; verify defaults are applied.
        let json = """
        {
            "id": "ent_minimal",
            "product_id": "com.app.lifetime",
            "is_active": true,
            "purchased_at": "2024-03-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let ent = try decoder.decode(Entitlement.self, from: json)

        XCTAssertEqual(ent.id, "ent_minimal")
        XCTAssertEqual(ent.productId, "com.app.lifetime")
        XCTAssertEqual(ent.source, .webCheckout, "Missing source should default to .webCheckout")
        XCTAssertTrue(ent.isActive)
        XCTAssertEqual(ent.status, .active, "Missing status should default to .active")
        XCTAssertNil(ent.pausedAt)
        XCTAssertNil(ent.pauseResumesAt)
        XCTAssertNil(ent.expiresAt)
        XCTAssertTrue(ent.willRenew, "Missing willRenew should default to true")
        XCTAssertFalse(ent.isTrial, "Missing isTrial should default to false")
        XCTAssertNil(ent.trialEndsAt)
        XCTAssertNil(ent.cancelledAt)
        XCTAssertFalse(ent.isPaused)
        XCTAssertFalse(ent.isCancelled)
    }

    // MARK: - Price Micros-to-Cents Conversion via Backend Wire Format

    func testPriceMicrosConversionInProductResponse() throws {
        // Verify the Price custom Codable correctly converts micros to cents
        // when decoded through the product catalog response path.
        let json = """
        {
            "products": [
                {
                    "id": "com.app.test",
                    "display_name": "Test",
                    "product_description": "Test product",
                    "type": "non_consumable",
                    "web_price": {
                        "amount_micros": 29990000,
                        "currency_code": "EUR"
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProductsResponse.self, from: json)
        let product = response.products[0]

        // 29,990,000 micros / 10,000 = 2,999 cents = $29.99
        XCTAssertEqual(product.webPrice?.amountCents, 2999)
        XCTAssertEqual(product.webPrice?.currencyCode, "EUR")
    }
}
