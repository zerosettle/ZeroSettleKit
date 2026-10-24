import XCTest
@testable import ZeroSettleKit

@MainActor
final class IdentityAnalyticsIdTests: XCTestCase {
    private let key = "zerosettle.anonymous_session_uuid"

    override func setUp() {
        super.setUp()
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testBeforeIdentifyIdIsStableUUIDAndCurrentUserIdIsNil() {
        XCTAssertNil(ZeroSettle.shared.currentUserId)
        let a = ZeroSettle.shared.analyticsUserId
        let b = ZeroSettle.shared.analyticsUserId
        XCTAssertEqual(a, b)
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertNil(ZeroSettle.shared.currentUserId)
    }

    func testIdentifyAnonymousAdoptsTheSameUUID() async {
        let before = ZeroSettle.shared.analyticsUserId
        _ = try? await ZeroSettle.shared.identify(.anonymous)
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
}
