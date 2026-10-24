import XCTest
@testable import ZeroSettleKit

@MainActor
final class IdentityStubbedBackendTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubbedSDK.setUp()
    }

    override func tearDown() {
        StubbedSDK.tearDown()
        super.tearDown()
    }

    private func reconcileJSON(from: String, into: String) -> String {
        #"{"reconciliation_id": 9, "from": "\#(from)", "into": "\#(into)", "moved": {"transactions": 1, "entitlements": 1}}"#
    }

    func testReconcileAdoptsAccountWhenCurrentIsFromAndClearsAbsorbedAnonymousId() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        StubURLProtocol.reconcileBody = reconcileJSON(from: anon, into: "acct-1")

        let result = try await ZeroSettle.shared.reconcile(linkToken: "tok")

        XCTAssertTrue(result.switchedToAccount)
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "acct-1")
        XCTAssertNil(UserDefaults.standard.string(forKey: StubbedSDK.anonymousKey))
        // A later anonymous session gets a fresh id, not the absorbed one.
        ZeroSettle.shared.logout()
        _ = try await ZeroSettle.shared.identify(.anonymous)
        XCTAssertNotEqual(ZeroSettle.shared.currentUserId, anon)
    }

    func testReconcileDoesNotAdoptWhenCurrentIsNotFrom() async throws {
        _ = try await ZeroSettle.shared.identify(.user(id: "someone-else"))
        StubURLProtocol.reconcileBody = reconcileJSON(from: "guest-1", into: "acct-1")

        let result = try await ZeroSettle.shared.reconcile(linkToken: "tok")

        XCTAssertFalse(result.switchedToAccount)
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "someone-else")
    }

    func testTrackEventSendsAnalyticsUserIdAndEnvironment() async throws {
        // Let the launch-time AppTransaction read settle, then pin a value if it failed.
        _ = await ZeroSettle.shared.storeKitEnvironmentWaitingBriefly()
        if ZeroSettle.shared.storeKitEnvironment == nil {
            ZeroSettle.shared.setStoreKitEnvironmentForTesting("Sandbox")
        }
        let expectedEnvironment = try XCTUnwrap(ZeroSettle.shared.storeKitEnvironment)
        let expectedUser = ZeroSettle.shared.analyticsUserId

        let sent = expectation(description: "event sent")
        StubURLProtocol.onRequest = { path in
            if path.contains("events") { sent.fulfill() }
        }
        ZeroSettle.trackEvent(.paywallViewed, productId: "p1")
        await fulfillment(of: [sent], timeout: 5)

        let body = try XCTUnwrap(StubURLProtocol.requests(matching: "events").first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["user_id"] as? String, expectedUser)
        XCTAssertEqual(json["environment"] as? String, expectedEnvironment)
        XCTAssertNotEqual(json["user_id"] as? String, "anonymous")
    }
}
