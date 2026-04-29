import XCTest
@testable import ZeroSettleKit

final class SubscriptionStateReconcileTests: XCTestCase {

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
        let response = try JSONDecoder().decode(ReconcileSubscriptionStatesResponse.self, from: json)
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
        let response = try JSONDecoder().decode(ReconcileSubscriptionStatesResponse.self, from: json)
        XCTAssertEqual(response.processed, 0)
        XCTAssertEqual(response.eventsEmitted, 0)
        XCTAssertNil(response.skipped)
    }
}
