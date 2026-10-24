import XCTest
@testable import ZeroSettleKit

final class ReconcileLinkTokenTests: XCTestCase {

    private func map(_ status: Int, _ json: String, headers: [String: String] = [:]) throws -> ReconcileResult {
        try Backend.mapReconcileResponse(statusCode: status, headers: headers, body: Data(json.utf8))
    }

    private func zsError(_ status: Int, _ json: String, headers: [String: String] = [:]) -> ZeroSettleError? {
        do { _ = try map(status, json, headers: headers); return nil }
        catch { return error as? ZeroSettleError }
    }

    func testDecodes200() throws {
        let r = try map(200, #"{"reconciliation_id": 7, "from": "guest-1", "into": "acct-1", "moved": {"transactions": 3, "entitlements": 2}}"#)
        XCTAssertEqual(r, ReconcileResult(reconciliationId: 7, fromUserId: "guest-1", intoUserId: "acct-1", movedTransactions: 3, movedEntitlements: 2))
    }

    func test409IsRefused() {
        XCTAssertEqual(zsError(409, #"{"error": {"code": "reconcile_refused"}}"#), .reconcileRefused)
    }

    func test401IsInvalidLinkToken() {
        XCTAssertEqual(zsError(401, #"{"error": {"code": "invalid_link_token"}}"#), .invalidLinkToken)
    }

    func test401WithOtherCodeIsApiError() {
        XCTAssertEqual(zsError(401, #"{"error": {"code": "invalid_key"}}"#)?.isApiError, true)
    }

    func test429WithRetryAfter() {
        XCTAssertEqual(zsError(429, "{}", headers: ["Retry-After": "30"]), .rateLimited(retryAfter: 30))
        XCTAssertEqual(zsError(429, "{}", headers: ["retry-after": "30"]), .rateLimited(retryAfter: 30))
    }

    func test429WithoutHeader() {
        XCTAssertEqual(zsError(429, "{}"), .rateLimited(retryAfter: nil))
    }

    func test500IsWrappedApiError() {
        guard case .apiError(let detail)? = zsError(500, #"{"message": "boom"}"#) else {
            return XCTFail("expected apiError")
        }
        XCTAssertEqual(detail.statusCode, 500)
    }

    @MainActor
    func testShouldAdoptReconciledUser() {
        XCTAssertTrue(ZeroSettle.shouldAdoptReconciledUser(currentUserId: "Guest-1", fromUserId: "guest-1"))
        XCTAssertFalse(ZeroSettle.shouldAdoptReconciledUser(currentUserId: "other", fromUserId: "guest-1"))
        XCTAssertFalse(ZeroSettle.shouldAdoptReconciledUser(currentUserId: nil, fromUserId: "guest-1"))
    }
}

private extension ZeroSettleError {
    var isApiError: Bool { if case .apiError = self { return true } else { return false } }
}
