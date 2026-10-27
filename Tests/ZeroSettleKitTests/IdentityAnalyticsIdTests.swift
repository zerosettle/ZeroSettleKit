import XCTest
@testable import ZeroSettleKit

@MainActor
final class IdentityAnalyticsIdTests: XCTestCase {
    private let key = "zerosettle.anonymous_session_uuid"

    override func setUp() {
        super.setUp()
        StubbedSDK.setUp()
    }

    override func tearDown() {
        StubbedSDK.tearDown()
        super.tearDown()
    }

    func testBeforeIdentifyIdIsStableUUIDAndCurrentUserIdIsNil() {
        XCTAssertNil(ZeroSettle.shared.currentUserId)
        let a = ZeroSettle.shared.analyticsUserId
        let b = ZeroSettle.shared.analyticsUserId
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("zs_anon_"))
        XCTAssertNotNil(UUID(uuidString: String(a.dropFirst("zs_anon_".count))))
        XCTAssertNil(ZeroSettle.shared.currentUserId)
    }

    func testIdentifyAnonymousAdoptsTheSameUUID() async {
        let before = ZeroSettle.shared.analyticsUserId
        _ = try? await ZeroSettle.shared.identify(.anonymous)
        XCTAssertEqual(ZeroSettle.shared.currentUserId, before)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before)
        XCTAssertEqual(ZeroSettle.shared.analyticsUserId, before)
    }

    func testLogoutProducesFreshUUID() {
        let before = ZeroSettle.shared.analyticsUserId
        ZeroSettle.shared.logout()
        XCTAssertNil(ZeroSettle.shared.currentUserId)
        XCTAssertNotEqual(ZeroSettle.shared.analyticsUserId, before)
    }

    func testSignedInUserIdWinsOverAnonymous() async {
        _ = ZeroSettle.shared.analyticsUserId
        _ = try? await ZeroSettle.shared.identify(.user(id: "u1"))
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "u1")
        XCTAssertEqual(ZeroSettle.shared.analyticsUserId, "u1")
    }

    func testImpressionDedupeKeysOnAnalyticsIdNotLiteralAnonymous() {
        let reporter = OfferImpressionReporter()
        let offer = ResolvedOffer(productId: "p", variantId: 1, flowType: "migration")
        XCTAssertTrue(reporter.shouldReportForTesting(offer))
        XCTAssertFalse(reporter.shouldReportForTesting(offer))
        // A different signed-out person (fresh UUID after logout) is a new key.
        ZeroSettle.shared.logout()
        XCTAssertTrue(reporter.shouldReportForTesting(offer))
    }
}
