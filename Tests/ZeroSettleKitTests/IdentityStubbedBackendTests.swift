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
        // Pin the value so a slow AppTransaction read cannot stall or change it.
        ZeroSettle.shared.setStoreKitEnvironmentForTesting("Sandbox")
        let expectedEnvironment = "Sandbox"
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

    func testEnvironmentWaitIsCappedWhenReadNeverFinishes() async {
        ZeroSettle.shared.setStoreKitEnvironmentForTesting(nil)
        ZeroSettle.shared.setNeverFinishingEnvironmentReadForTesting(true)
        defer { ZeroSettle.shared.setNeverFinishingEnvironmentReadForTesting(false) }
        let start = Date()
        let value = await ZeroSettle.shared.storeKitEnvironmentWaitingBriefly()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(value)
        XCTAssertGreaterThan(elapsed, 1.0)
        XCTAssertLessThan(elapsed, 3.0)
    }
}
