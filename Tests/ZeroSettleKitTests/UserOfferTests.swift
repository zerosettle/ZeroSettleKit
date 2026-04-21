//
//  UserOfferTests.swift
//  ZeroSettleKitTests
//
//  Decoding tests for the unified /v1/iap/user-offer/ response schema.
//  Uses the same decoder configuration as Backend (snake_case + ISO 8601).
//

import XCTest
@testable import ZeroSettleKit

final class UserOfferDecodingTests: XCTestCase {

    private var decoder: JSONDecoder!

    override func setUp() {
        super.setUp()
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Happy path: no action

    func testDecodeNoActionResponse() throws {
        let json = """
        {
          "user_id": "abc",
          "app_id": 1,
          "is_sandbox": true,
          "subscription": { "type": "none" },
          "offer": {
            "action_type": "no_action",
            "is_eligible": false,
            "checkout_product_id": "",
            "from_product_id": null,
            "savings_percent": 0,
            "free_trial_days": 0,
            "min_subscription_days": 0,
            "display": null,
            "proration": null,
            "requires_apple_cancel": false,
            "apple_subscription": null,
            "checkout_presentation": null,
            "experiment_variant_id": null
          },
          "server_time": "2026-04-20T00:00:00+00:00"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(UserOffer.Response.self, from: json)
        XCTAssertEqual(response.userId, "abc")
        XCTAssertEqual(response.appId, 1)
        XCTAssertTrue(response.isSandbox)
        XCTAssertEqual(response.offer.actionType, .noAction)
        XCTAssertFalse(response.offer.isEligible)
        XCTAssertNil(response.offer.display)
        XCTAssertNil(response.offer.proration)
        XCTAssertNil(response.offer.appleSubscription)
        XCTAssertNil(response.offer.checkoutPresentation)
        if case .none = response.subscription {} else { XCTFail("Expected .none subscription") }
    }

    // MARK: - Migration: StoreKit → Web

    func testDecodeMigrationResponse() throws {
        let json = """
        {
          "user_id": "u",
          "app_id": 1,
          "is_sandbox": false,
          "subscription": { "type": "active_storekit", "product_id": "com.app.premium" },
          "offer": {
            "action_type": "migrate_storekit_to_web",
            "is_eligible": true,
            "checkout_product_id": "com.app.zs.premium",
            "from_product_id": "com.app.premium",
            "savings_percent": 15,
            "free_trial_days": 3,
            "min_subscription_days": 0,
            "display": {
              "title": "T", "body": "B", "cta_text": "C", "dismiss_text": "D",
              "accepted_title": "A1", "accepted_body": "A2",
              "completed_title": "C1", "completed_body": "C2",
              "apple_cancel_instructions": ""
            },
            "proration": null,
            "requires_apple_cancel": true,
            "apple_subscription": {
              "is_active": true,
              "expires_at": "2026-05-20T00:00:00+00:00",
              "status_code": 1,
              "auto_renew_enabled": true
            },
            "checkout_presentation": "native_pay",
            "experiment_variant_id": null
          },
          "server_time": "2026-04-20T00:00:00+00:00"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(UserOffer.Response.self, from: json)
        XCTAssertEqual(response.offer.actionType, .migrateStorekitToWeb)
        XCTAssertTrue(response.offer.isEligible)
        XCTAssertEqual(response.offer.checkoutProductId, "com.app.zs.premium")
        XCTAssertEqual(response.offer.fromProductId, "com.app.premium")
        XCTAssertEqual(response.offer.savingsPercent, 15)
        XCTAssertEqual(response.offer.freeTrialDays, 3)
        XCTAssertEqual(response.offer.display?.title, "T")
        XCTAssertEqual(response.offer.display?.ctaText, "C")
        XCTAssertEqual(response.offer.display?.appleCancelInstructions, "")
        XCTAssertTrue(response.offer.requiresAppleCancel)
        XCTAssertEqual(response.offer.appleSubscription?.statusCode, 1)
        XCTAssertTrue(response.offer.appleSubscription?.isActive ?? false)
        XCTAssertTrue(response.offer.appleSubscription?.autoRenewEnabled ?? false)
        XCTAssertEqual(response.offer.checkoutPresentation, .nativePay)

        if case .activeStorekit(let sk) = response.subscription {
            XCTAssertEqual(sk.productId, "com.app.premium")
        } else {
            XCTFail("Expected .activeStorekit subscription")
        }
    }

    // MARK: - Upgrade: Web → Web (with proration)

    func testDecodeWebToWebUpgradeResponse() throws {
        let json = """
        {
          "user_id": "u2",
          "app_id": 7,
          "is_sandbox": false,
          "subscription": { "type": "active_web", "product_id": "com.app.zs.weekly" },
          "offer": {
            "action_type": "upgrade_web_to_web",
            "is_eligible": true,
            "checkout_product_id": "com.app.zs.monthly",
            "from_product_id": "com.app.zs.weekly",
            "savings_percent": 20,
            "free_trial_days": 0,
            "min_subscription_days": 0,
            "display": {
              "title": "Upgrade", "body": "Save 20%", "cta_text": "Upgrade", "dismiss_text": "Not now",
              "accepted_title": "Upgraded", "accepted_body": "Thanks",
              "completed_title": "Done", "completed_body": "You're on monthly",
              "apple_cancel_instructions": ""
            },
            "proration": {
              "amount_cents": -169,
              "currency": "usd",
              "next_billing_date": "2026-05-20T00:00:00+00:00"
            },
            "requires_apple_cancel": false,
            "apple_subscription": null,
            "checkout_presentation": "webview",
            "experiment_variant_id": 42
          },
          "server_time": "2026-04-20T00:00:00+00:00"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(UserOffer.Response.self, from: json)
        XCTAssertEqual(response.offer.actionType, .upgradeWebToWeb)
        XCTAssertEqual(response.offer.proration?.amountCents, -169)
        XCTAssertEqual(response.offer.proration?.currency, "usd")
        XCTAssertNotNil(response.offer.proration?.nextBillingDate)
        XCTAssertFalse(response.offer.requiresAppleCancel)
        XCTAssertEqual(response.offer.checkoutPresentation, .webview)
        XCTAssertEqual(response.offer.experimentVariantId, 42)

        if case .activeWeb(let web) = response.subscription {
            XCTAssertEqual(web.productId, "com.app.zs.weekly")
        } else {
            XCTFail("Expected .activeWeb subscription")
        }
    }

    // MARK: - Forward compat: unknown subscription type

    func testDecodeUnknownSubscriptionType() throws {
        let json = """
        {
          "user_id": "u", "app_id": 1, "is_sandbox": false,
          "subscription": { "type": "future_variant" },
          "offer": {
            "action_type": "no_action", "is_eligible": false,
            "checkout_product_id": "", "from_product_id": null,
            "savings_percent": 0, "free_trial_days": 0, "min_subscription_days": 0,
            "display": null, "proration": null, "requires_apple_cancel": false,
            "apple_subscription": null, "checkout_presentation": null,
            "experiment_variant_id": null
          },
          "server_time": "2026-04-20T00:00:00+00:00"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(UserOffer.Response.self, from: json)
        if case .unknown(let type) = response.subscription {
            XCTAssertEqual(type, "future_variant")
        } else {
            XCTFail("Expected .unknown fallback")
        }
    }

    // MARK: - Migration trial + cancelled active variants

    func testDecodeMigrationTrialSubscription() throws {
        let json = """
        {
          "user_id": "u", "app_id": 1, "is_sandbox": false,
          "subscription": { "type": "migration_trial", "product_id": "com.app.zs.premium" },
          "offer": {
            "action_type": "no_action", "is_eligible": false,
            "checkout_product_id": "", "from_product_id": null,
            "savings_percent": 0, "free_trial_days": 0, "min_subscription_days": 0,
            "display": null, "proration": null, "requires_apple_cancel": false,
            "apple_subscription": null, "checkout_presentation": null,
            "experiment_variant_id": null
          },
          "server_time": "2026-04-20T00:00:00+00:00"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(UserOffer.Response.self, from: json)
        if case .migrationTrial(let trial) = response.subscription {
            XCTAssertEqual(trial.productId, "com.app.zs.premium")
        } else {
            XCTFail("Expected .migrationTrial subscription")
        }
    }

    func testDecodeCancelledActiveSubscription() throws {
        let json = """
        {
          "user_id": "u", "app_id": 1, "is_sandbox": false,
          "subscription": { "type": "cancelled_active", "product_id": "com.app.zs.premium" },
          "offer": {
            "action_type": "no_action", "is_eligible": false,
            "checkout_product_id": "", "from_product_id": null,
            "savings_percent": 0, "free_trial_days": 0, "min_subscription_days": 0,
            "display": null, "proration": null, "requires_apple_cancel": false,
            "apple_subscription": null, "checkout_presentation": null,
            "experiment_variant_id": null
          },
          "server_time": "2026-04-20T00:00:00+00:00"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(UserOffer.Response.self, from: json)
        if case .cancelledActive(let cancelled) = response.subscription {
            XCTAssertEqual(cancelled.productId, "com.app.zs.premium")
        } else {
            XCTFail("Expected .cancelledActive subscription")
        }
    }

    // MARK: - Round-trip encode/decode

    func testRoundTripEncodeDecode() throws {
        // Start from a known Response, encode it, then decode back.
        // Uses the same snake_case + ISO8601 configuration as the wire protocol.
        let original = UserOffer.Response(
            userId: "abc",
            appId: 1,
            isSandbox: false,
            subscription: .activeStorekit(.init(productId: "com.app.premium")),
            offer: UserOffer.OfferData(
                actionType: .migrateStorekitToWeb,
                isEligible: true,
                checkoutProductId: "com.app.zs.premium",
                fromProductId: "com.app.premium",
                savingsPercent: 20,
                freeTrialDays: 3,
                minSubscriptionDays: 0,
                display: nil,
                proration: nil,
                requiresAppleCancel: true,
                appleSubscription: nil,
                checkoutPresentation: .nativePay,
                experimentVariantId: nil
            ),
            serverTime: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(UserOffer.Response.self, from: data)

        XCTAssertEqual(decoded.userId, original.userId)
        XCTAssertEqual(decoded.offer.actionType, original.offer.actionType)
        XCTAssertEqual(decoded.offer.checkoutPresentation, original.offer.checkoutPresentation)
        XCTAssertEqual(decoded, original)
    }
}
