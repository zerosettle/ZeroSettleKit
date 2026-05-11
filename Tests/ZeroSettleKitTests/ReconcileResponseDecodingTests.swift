import XCTest
@testable import ZeroSettleKit

/// Regression tests for the `.convertFromSnakeCase` + explicit-CodingKeys bug.
///
/// The bug: when `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` is set AND
/// a `Decodable` struct declares an explicit `CodingKeys` enum with snake_case
/// raw values, the decoder fails to find the key even when the JSON contains it.
///
/// Reason: the strategy transforms JSON keys to camelCase BEFORE matching them
/// against `CodingKey` raw values. A `case eventsEmitted = "events_emitted"`
/// expects the raw value `"events_emitted"`, but the transformed JSON key is
/// `"eventsEmitted"` (camelCase). The lookup misses; if the property is non-optional,
/// the decoder throws `keyNotFound`; if optional, the value is silently `nil`.
///
/// Fix: remove the explicit `CodingKeys` from `Decodable` response structs and rely
/// on `.convertFromSnakeCase` to handle the snake_case → camelCase mapping. All
/// affected structs have Swift properties already in camelCase, so this is purely
/// removing dead/broken code.
///
/// These tests use the SAME decoder configuration as production (`Backend.swift:35`).
@available(iOS 17.0, *)
final class ReconcileResponseDecodingTests: XCTestCase {

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - ReconcileSubscriptionStatesResponse

    /// Production response shape captured via `curl` against staging:
    /// `{"status":"ok","processed":0,"events_emitted":0,"skipped":[]}`.
    func test_decode_reconcile_response_with_all_fields() throws {
        let json = """
        {"status": "ok", "processed": 0, "events_emitted": 0, "skipped": []}
        """.data(using: .utf8)!
        let response = try makeDecoder().decode(
            ReconcileSubscriptionStatesResponse.self, from: json
        )
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.processed, 0)
        XCTAssertEqual(response.eventsEmitted, 0,
                       "events_emitted (snake_case in JSON) must decode into eventsEmitted via .convertFromSnakeCase")
        XCTAssertEqual(response.skipped?.count, 0)
    }

    /// Skipped entry with `transaction_id` populated must decode correctly.
    /// Before the fix, `SkipEntry.transactionId` had an explicit
    /// `case transactionId = "transaction_id"` that broke under
    /// `.convertFromSnakeCase` — the property was silently nil.
    func test_decode_reconcile_skipped_entry_with_transaction_id() throws {
        let json = """
        {
            "status": "ok",
            "processed": 1,
            "events_emitted": 0,
            "skipped": [
                {"reason": "jws_verification_failed", "transaction_id": "txn_001"}
            ]
        }
        """.data(using: .utf8)!
        let response = try makeDecoder().decode(
            ReconcileSubscriptionStatesResponse.self, from: json
        )
        XCTAssertEqual(response.skipped?.count, 1)
        let skipped = try XCTUnwrap(response.skipped?.first)
        XCTAssertEqual(skipped.reason, "jws_verification_failed")
        XCTAssertEqual(skipped.transactionId, "txn_001",
                       "transaction_id (snake_case in JSON) must decode into transactionId")
    }

    /// Backend can return `transaction_id: null` (Python `None`) for skips
    /// where the transaction ID wasn't extractable (e.g., JWS verification failed
    /// before the payload was parsed). `transactionId: String?` must accept null.
    func test_decode_reconcile_skipped_entry_with_null_transaction_id() throws {
        let json = """
        {
            "status": "ok",
            "processed": 1,
            "events_emitted": 0,
            "skipped": [
                {"reason": "jws_verification_failed", "transaction_id": null}
            ]
        }
        """.data(using: .utf8)!
        let response = try makeDecoder().decode(
            ReconcileSubscriptionStatesResponse.self, from: json
        )
        let skipped = try XCTUnwrap(response.skipped?.first)
        XCTAssertNil(skipped.transactionId)
    }

    /// Backend always returns `events_emitted` on the reconcile endpoint
    /// (success path at `api/iap_views.py:7811`). The field is non-optional
    /// on the response struct; if the backend ever omitted it, decoding
    /// should fail loudly so we notice. This test guards that contract.
    func test_decode_reconcile_response_throws_when_events_emitted_missing() throws {
        let json = """
        {"status": "ok", "processed": 0, "skipped": []}
        """.data(using: .utf8)!
        XCTAssertThrowsError(
            try makeDecoder().decode(
                ReconcileSubscriptionStatesResponse.self, from: json
            )
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected DecodingError.keyNotFound, got \(error)")
                return
            }
            // After fix, the looked-up key is "eventsEmitted" (the implicit
            // CodingKey rawValue, not snake_case). The decoder reports the
            // CodingKey it tried to match.
            XCTAssertEqual(key.stringValue, "eventsEmitted",
                           "After the fix, the implicit CodingKey rawValue is camelCase 'eventsEmitted'.")
        }
    }

    // MARK: - SyncStoreKitTransactionResponse

    /// Same .convertFromSnakeCase + CodingKeys bug applied to this struct
    /// (it had explicit `case originalTransactionId = "original_transaction_id"` etc).
    func test_decode_sync_storekit_response_with_snake_case_fields() throws {
        let json = """
        {
            "status": "ok",
            "owned": true,
            "original_transaction_id": "1000000123456789",
            "conflict": false,
            "claim_available": false,
            "existing_owner_hint": null
        }
        """.data(using: .utf8)!
        let response = try makeDecoder().decode(
            SyncStoreKitTransactionResponse.self, from: json
        )
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.owned, true)
        XCTAssertEqual(response.originalTransactionId, "1000000123456789",
                       "original_transaction_id (snake_case) must decode into originalTransactionId")
        XCTAssertEqual(response.conflict, false)
        XCTAssertEqual(response.claimAvailable, false)
        XCTAssertNil(response.existingOwnerHint)
    }

    /// Cross-user OTID conflict response — all optional fields present.
    func test_decode_sync_storekit_response_with_conflict_signals() throws {
        let json = """
        {
            "status": "conflict",
            "owned": false,
            "original_transaction_id": "1000000999999999",
            "conflict": true,
            "claim_available": true,
            "existing_owner_hint": "alice@example.com"
        }
        """.data(using: .utf8)!
        let response = try makeDecoder().decode(
            SyncStoreKitTransactionResponse.self, from: json
        )
        XCTAssertEqual(response.conflict, true)
        XCTAssertEqual(response.claimAvailable, true)
        XCTAssertEqual(response.existingOwnerHint, "alice@example.com")
    }

    // MARK: - ClaimEntitlementResponse

    /// Same .convertFromSnakeCase + CodingKeys bug applied to this struct
    /// (it had explicit `case productId = "product_id"` and
    /// `case originalTransactionId = "original_transaction_id"`).
    func test_decode_claim_entitlement_response_with_snake_case_fields() throws {
        let json = """
        {
            "status": "ok",
            "claimed": true,
            "product_id": "com.example.pro_monthly",
            "original_transaction_id": "1000000123456789",
            "message": "Entitlement claimed successfully"
        }
        """.data(using: .utf8)!
        let response = try makeDecoder().decode(
            ClaimEntitlementResponse.self, from: json
        )
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.claimed, true)
        XCTAssertEqual(response.productId, "com.example.pro_monthly",
                       "product_id (snake_case) must decode into productId")
        XCTAssertEqual(response.originalTransactionId, "1000000123456789",
                       "original_transaction_id (snake_case) must decode into originalTransactionId")
        XCTAssertEqual(response.message, "Entitlement claimed successfully")
    }
}
