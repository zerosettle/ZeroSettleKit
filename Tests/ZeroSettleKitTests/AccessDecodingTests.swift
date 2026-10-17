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

    func test_bad_balance_drops_only_itself() {
        let good = #"{"currency": {"key": "credits", "name": "Credit", "plural": "Credits", "glyph": "g", "offline": "allow"}, "remaining": 1, "limit": 2, "resets_at": null, "allowance_remaining": 1, "rolled_over": 0, "purchased": 0}"#
        let badDate = good.replacingOccurrences(of: #""resets_at": null"#, with: #""resets_at": "not a date""#)
        let result = access(#"{"plan": {"key": "pro", "name": "Pro", "kind": "tier"}, "features": {"a": true}, "balances": {"credits": \#(good), "bad": {"remaining": "x"}, "baddate": \#(badDate)}}"#)
        XCTAssertEqual(result.balances.keys.sorted(), ["credits"])
        XCTAssertEqual(result.plan?.key, "pro")
        XCTAssertEqual(result.features["a"], .bool(true))
        XCTAssertTrue(result.isPresent)
    }

    func test_bad_plan_keeps_features_and_empty_features_is_present() {
        let result = access(#"{"plan": {"key": 5}, "add_ons": [{"nope": 1}, {"key": "p", "name": "P", "kind": "add_on"}], "features": {}}"#)
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.addOns.map(\.key), ["p"])
        XCTAssertTrue(result.isPresent)
    }

    func test_fractional_second_dates() {
        let expected = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
        for stamp in ["2026-11-03T00:00:00.123456+00:00", "2026-11-03T00:00:00.123Z", "2026-11-03T00:00:00Z", "2026-11-03T00:00:00+00:00"] {
            let result = access(#"{"balances": {"c": {"currency": {"key": "c", "name": "C", "plural": "Cs", "glyph": "g", "offline": "allow"}, "remaining": 1, "limit": 1, "resets_at": "\#(stamp)", "allowance_remaining": 1, "rolled_over": 0, "purchased": 0}}}"#)
            let date = result.balances["c"]?.resetsAt
            XCTAssertNotNil(date, stamp)
            XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1, stamp)
        }
    }

    @MainActor
    func test_feature_keys_keep_underscores_through_get_entitlements() async throws {
        StubURLProtocol.body = Data("""
        {"entitlements": [{"id": "e1", "product_id": "pro", "source": "web_checkout", "is_active": true, "status": "active", "purchased_at": "2026-10-01T00:00:00Z"}],
         "features": {"custom_styles": true}}
        """.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let backend = Backend(baseURL: URL(string: "https://example.test")!, publishableKey: "zs_pk_test_x", session: URLSession(configuration: config))
        let read = try await backend.getEntitlements(userId: "u1")
        XCTAssertEqual(read.access.features["custom_styles"], .bool(true))
        XCTAssertNil(read.access.features["customStyles"])
        XCTAssertEqual(read.entitlements.map(\.productId), ["pro"])
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
