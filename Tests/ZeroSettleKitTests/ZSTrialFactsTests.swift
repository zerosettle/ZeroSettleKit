//
//  ZSTrialFactsTests.swift
//  ZeroSettleKitTests
//
//  TDD tests for ZSTrialFacts decoding from the backend products wire format.
//  The backend sends a snake_case `trial` object; the production decoder uses
//  `.convertFromSnakeCase` so camelCase Swift properties map automatically.
//
import XCTest
@testable import ZeroSettleKit

final class ZSTrialFactsTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func productJSON(trial: String) -> Data {
        """
        {
          "id": "com.app.pro",
          "display_name": "Pro",
          "product_description": "Pro plan",
          "type": "auto_renewable_subscription",
          "free_trial_duration": "1_week",
          "is_trial_eligible": true
          \(trial)
        }
        """.data(using: .utf8)!
    }

    func test_paid_trial_decodes() throws {
        let json = productJSON(trial: """
        , "trial": {"mode": "paid", "duration": "1_week", "upfront_amount_cents": 100, "hold_amount_cents": 0, "validates_card": true}
        """)
        let p = try decoder().decode(ZSProduct.self, from: json)
        XCTAssertEqual(p.trial?.mode, .paid)
        XCTAssertEqual(p.trial?.upfrontAmountCents, 100)
        XCTAssertEqual(p.trial?.holdAmountCents, 0)
        XCTAssertEqual(p.trial?.validatesCard, true)
        XCTAssertEqual(p.trial?.duration, "1_week")
    }

    func test_auth_hold_trial_decodes() throws {
        let json = productJSON(trial: """
        , "trial": {"mode": "auth_hold", "duration": "1_week", "upfront_amount_cents": 0, "hold_amount_cents": 100, "validates_card": true}
        """)
        let p = try decoder().decode(ZSProduct.self, from: json)
        XCTAssertEqual(p.trial?.mode, .authHold)
        XCTAssertEqual(p.trial?.holdAmountCents, 100)
    }

    func test_free_trial_decodes() throws {
        let json = productJSON(trial: """
        , "trial": {"mode": "free", "duration": "1_week", "upfront_amount_cents": 0, "hold_amount_cents": 0, "validates_card": false}
        """)
        let p = try decoder().decode(ZSProduct.self, from: json)
        XCTAssertEqual(p.trial?.mode, .free)
        XCTAssertEqual(p.trial?.validatesCard, false)
    }

    func test_absent_trial_is_nil() throws {
        let p = try decoder().decode(ZSProduct.self, from: productJSON(trial: ""))
        XCTAssertNil(p.trial)
    }

    func test_unknown_mode_decodes_to_nil_trial_not_failure() throws {
        let json = productJSON(trial: """
        , "trial": {"mode": "future_mode", "duration": "1_week", "upfront_amount_cents": 0, "hold_amount_cents": 0, "validates_card": false}
        """)
        let p = try decoder().decode(ZSProduct.self, from: json)
        XCTAssertNil(p.trial)
        XCTAssertEqual(p.id, "com.app.pro")
    }
}
