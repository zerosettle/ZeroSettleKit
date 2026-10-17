//
//  AccessDecodingTests.swift
//  ZeroSettleKitTests
//
//  Decoding of plan, add-ons, features and balances from the entitlements read.
//

import XCTest
@testable import ZeroSettleKit

final class AccessDecodingTests: XCTestCase {

    private func access(_ json: String) -> ZSAccess {
        ZSAccess.decode(from: Data(json.utf8))
    }

    func test_feature_keys_keep_underscores() {
        let result = access(#"{"entitlements": [], "features": {"custom_styles": true, "export_quality": "4K"}}"#)
        XCTAssertEqual(result.features["custom_styles"], .bool(true))
        XCTAssertEqual(result.features["export_quality"], .text("4K"))
        XCTAssertNil(result.features["customStyles"])
        XCTAssertTrue(result.isPresent)
    }

    func test_response_without_access_keys() throws {
        let json = #"{"entitlements": [], "pending_actions": []}"#
        let result = access(json)
        XCTAssertFalse(result.isPresent)
        XCTAssertNil(result.plan)
        XCTAssertTrue(result.features.isEmpty)
        XCTAssertEqual(result, .empty)

        // The shared decoder still reads the rows as before.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Rows: Decodable { let entitlements: [Entitlement] }
        XCTAssertTrue(try decoder.decode(Rows.self, from: Data(json.utf8)).entitlements.isEmpty)
    }

    func test_full_payload_decodes() {
        let result = access("""
        {
          "entitlements": [],
          "plan": {"key": "pro", "name": "Pro", "kind": "tier"},
          "add_ons": [{"key": "priority", "name": "Priority", "kind": "add_on"}],
          "features": {"custom_styles": true, "export_quality": "4K"},
          "balances": {"credits": {
            "currency": {"key": "credits", "name": "Credit", "plural": "Credits", "glyph": "sparkles", "offline": "allow"},
            "remaining": 318, "limit": 500, "resets_at": "2026-11-03T00:00:00Z",
            "allowance_remaining": 300, "rolled_over": 5, "purchased": 13
          }}
        }
        """)
        XCTAssertEqual(result.plan, ZSPlan(key: "pro", name: "Pro", kind: .tier))
        XCTAssertEqual(result.addOns, [ZSPlan(key: "priority", name: "Priority", kind: .addOn)])
        let balance = result.balances["credits"]
        XCTAssertEqual(balance?.currency.glyph, "sparkles")
        XCTAssertEqual(balance?.currency.offline, "allow")
        XCTAssertEqual(balance?.remaining, 318)
        XCTAssertEqual(balance?.limit, 500)
        XCTAssertEqual(balance?.allowanceRemaining, 300)
        XCTAssertEqual(balance?.rolledOver, 5)
        XCTAssertEqual(balance?.purchased, 13)
        XCTAssertEqual(balance?.resetsAt, ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z"))
    }

    func test_unknown_plan_kind_and_bad_feature_value_tolerated() {
        let result = access("""
        {"plan": {"key": "x", "name": "X", "kind": "bundle"},
         "features": {"ok": true, "seats": 5, "nested": {"a": 1}, "label": "Pro"}}
        """)
        XCTAssertEqual(result.plan?.kind, .unknown)
        XCTAssertEqual(result.features["ok"], .bool(true))
        XCTAssertEqual(result.features["label"], .text("Pro"))
        XCTAssertNil(result.features["seats"])
        XCTAssertNil(result.features["nested"])
    }

    func test_balance_null_limit_and_resets_at() {
        let result = access("""
        {"balances": {"packs": {
          "currency": {"key": "packs", "name": "Pack", "plural": "Packs", "glyph": "box", "offline": "stop"},
          "remaining": 4, "limit": null, "resets_at": null,
          "allowance_remaining": 0, "rolled_over": 0, "purchased": 4
        }}}
        """)
        let balance = result.balances["packs"]
        XCTAssertNil(balance?.limit)
        XCTAssertNil(balance?.resetsAt)
        XCTAssertEqual(balance?.remaining, 4)
        XCTAssertTrue(result.isPresent)
    }

    func test_encode_round_trip_keeps_keys() throws {
        let original = access(#"{"plan": null, "features": {"custom_styles": true}}"#)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ZSAccess.self, from: data)
        XCTAssertEqual(decoded.features["custom_styles"], .bool(true))
        XCTAssertTrue(decoded.isPresent)
    }
}
