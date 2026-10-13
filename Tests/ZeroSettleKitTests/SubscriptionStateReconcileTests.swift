import XCTest
@testable import ZeroSettleKit

final class SubscriptionStateReconcileTests: XCTestCase {

    /// Production decoder configuration. The shared Backend decoder uses
    /// `.convertFromSnakeCase` (see Backend.swift:35), so tests MUST too.
    /// A plain `JSONDecoder()` tests the wrong configuration and previously
    /// allowed `.convertFromSnakeCase` + explicit-CodingKeys bugs to slip
    /// through (the existing reconcile-response tests passed against a
    /// broken-in-production struct because the default decoder was used).
    private func productionDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testEntryEncodesWithSignedTransactionOnly() throws {
        let entry = SubscriptionStateEntry(
            signedTransaction: "fake-tx-jws",
            signedRenewalInfo: nil
        )
        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["signedTransaction"] as? String, "fake-tx-jws")
        if let val = json["signedRenewalInfo"] {
            XCTAssertTrue(val is NSNull, "signedRenewalInfo should be null when nil, got \(val)")
        }
    }

    func testEntryEncodesWithSignedRenewalInfo() throws {
        let entry = SubscriptionStateEntry(
            signedTransaction: "tx",
            signedRenewalInfo: "rinfo"
        )
        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["signedTransaction"] as? String, "tx")
        XCTAssertEqual(json["signedRenewalInfo"] as? String, "rinfo")
    }

    func testReconcileResponseDecodesWithSkipped() throws {
        let json = """
        {
          "status": "ok",
          "processed": 3,
          "events_emitted": 1,
          "skipped": [
            { "reason": "stale_signed_date", "transaction_id": "999" }
          ]
        }
        """.data(using: .utf8)!
        let response = try productionDecoder().decode(ReconcileSubscriptionStatesResponse.self, from: json)
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.processed, 3)
        XCTAssertEqual(response.eventsEmitted, 1)
        XCTAssertEqual(response.skipped?.count, 1)
        XCTAssertEqual(response.skipped?.first?.reason, "stale_signed_date")
        XCTAssertEqual(response.skipped?.first?.transactionId, "999")
    }

    func testReconcileResponseDecodesWithoutSkipped() throws {
        let json = """
        { "status": "ok", "processed": 0, "events_emitted": 0 }
        """.data(using: .utf8)!
        let response = try productionDecoder().decode(ReconcileSubscriptionStatesResponse.self, from: json)
        XCTAssertEqual(response.processed, 0)
        XCTAssertEqual(response.eventsEmitted, 0)
        XCTAssertNil(response.skipped)
    }

    // MARK: - Selection and filtering

    private func cand(
        _ id: UInt64, otid: UInt64 = 1, at t: TimeInterval = 0,
        token: UUID? = nil, renewal: String? = nil, group: String? = "g"
    ) -> ReconcileCandidate {
        ReconcileCandidate(
            id: id, originalID: otid, purchaseDate: Date(timeIntervalSince1970: t),
            appAccountToken: token, signedTransaction: "tx\(id)",
            signedRenewalInfo: renewal, subscriptionGroupID: group
        )
    }

    func testFallbackPicksLatestPerOriginalID() {
        let picked = SubscriptionStateReconciler.latestPerOriginalID([
            cand(1, otid: 1, at: 10), cand(2, otid: 1, at: 30), cand(3, otid: 1, at: 20),
            cand(4, otid: 2, at: 5),
        ])
        XCTAssertEqual(picked.map(\.id), [2, 4])
    }

    func testFallbackTieBreaksOnGreaterID() {
        let picked = SubscriptionStateReconciler.latestPerOriginalID([
            cand(7, at: 10), cand(9, at: 10), cand(8, at: 10),
        ])
        XCTAssertEqual(picked.map(\.id), [9])
    }

    func testSelectFallsBackOnlyForGroupsWhoseStatusFailed() {
        let txns = [
            cand(1, otid: 1, at: 1, group: "ok"), cand(2, otid: 1, at: 2, group: "ok"),
            cand(3, otid: 2, at: 1, group: "bad"), cand(4, otid: 2, at: 2, group: "bad"),
        ]
        let status = cand(2, otid: 1, at: 2, renewal: "r", group: "ok")
        let out = SubscriptionStateReconciler.select(
            transactions: txns, statusesByGroup: ["ok": [status]]
        )
        XCTAssertEqual(out.map(\.id), [2, 4])
        XCTAssertEqual(out.first { $0.id == 2 }?.signedRenewalInfo, "r")
        XCTAssertNil(out.first { $0.id == 4 }?.signedRenewalInfo)
    }

    func testNonSubscriptionsDedupedByID() {
        let txns = [
            cand(1, group: nil), cand(1, group: nil), cand(2, group: nil),
        ]
        let out = SubscriptionStateReconciler.select(transactions: txns, statusesByGroup: [:])
        XCTAssertEqual(out.map(\.id), [1, 2])
    }

    func testStatusEntriesDedupedByID() {
        let a = cand(5, renewal: "r1", group: "g1")
        let b = cand(5, renewal: "r1", group: "g2")
        let out = SubscriptionStateReconciler.select(
            transactions: [], statusesByGroup: ["g1": [a], "g2": [b]]
        )
        XCTAssertEqual(out.count, 1)
    }

    func testFilterKeepsNilDerivedAndUUIDPassthroughTokens() {
        let derived = AppAccountToken.derive(userId: "firebase-uid", bundleId: "com.app")
        let expected = SubscriptionStateReconciler.expectedToken(userId: "firebase-uid", bundleId: "com.app")
        XCTAssertEqual(expected, derived)
        let kept = SubscriptionStateReconciler.dropForeign(
            [cand(1, token: nil), cand(2, token: derived)], expectedToken: expected
        )
        XCTAssertEqual(kept.map(\.id), [1, 2])

        let uuid = UUID()
        let uuidExpected = SubscriptionStateReconciler.expectedToken(userId: uuid.uuidString, bundleId: "com.app")
        XCTAssertEqual(uuidExpected, uuid)
        XCTAssertEqual(
            SubscriptionStateReconciler.dropForeign([cand(3, token: uuid)], expectedToken: uuidExpected).count, 1
        )
    }

    func testFilterDropsForeignToken() {
        let expected = SubscriptionStateReconciler.expectedToken(userId: "u", bundleId: "com.app")
        let out = SubscriptionStateReconciler.dropForeign(
            [cand(1, token: UUID())], expectedToken: expected
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testNilOrEmptyInputsSkipFilter() {
        XCTAssertNil(SubscriptionStateReconciler.expectedToken(userId: "u", bundleId: nil))
        XCTAssertNil(SubscriptionStateReconciler.expectedToken(userId: "u", bundleId: ""))
        XCTAssertNil(SubscriptionStateReconciler.expectedToken(userId: nil, bundleId: "com.app"))
        XCTAssertNil(SubscriptionStateReconciler.expectedToken(userId: "", bundleId: "com.app"))
        let foreign = cand(1, token: UUID())
        XCTAssertEqual(SubscriptionStateReconciler.dropForeign([foreign], expectedToken: nil), [foreign])
    }

    func testFilterRunsAfterSelection() {
        let mine = AppAccountToken.derive(userId: "u", bundleId: "com.app")
        let txns = [
            cand(1, at: 10, token: mine),
            cand(2, at: 20, token: UUID()),
        ]
        let selected = SubscriptionStateReconciler.select(transactions: txns, statusesByGroup: [:])
        let out = SubscriptionStateReconciler.dropForeign(selected, expectedToken: mine)
        XCTAssertTrue(out.isEmpty, "older matching txn must not replace the newer foreign one")
    }
}
