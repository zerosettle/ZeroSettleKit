import XCTest
@testable import ZeroSettleKit

@MainActor
final class IdentitySwitchWarningTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ZeroSettle.shared.logout()
    }

    override func tearDown() {
        ZeroSettle.shared.logout()
        super.tearDown()
    }

    private func warnings() -> Int { ZeroSettle.shared.userSwitchWarningCount }

    func testUserToDifferentUserWarns() async {
        let start = warnings()
        _ = try? await ZeroSettle.shared.identify(.user(id: "A"))
        _ = try? await ZeroSettle.shared.identify(.user(id: "B"))
        XCTAssertEqual(warnings(), start + 1)
    }

    func testSameUserCaseInsensitiveDoesNotWarn() async {
        let start = warnings()
        _ = try? await ZeroSettle.shared.identify(.user(id: "A"))
        _ = try? await ZeroSettle.shared.identify(.user(id: "a"))
        XCTAssertEqual(warnings(), start)
    }

    func testLogoutBetweenUsersDoesNotWarn() async {
        let start = warnings()
        _ = try? await ZeroSettle.shared.identify(.user(id: "A"))
        ZeroSettle.shared.logout()
        _ = try? await ZeroSettle.shared.identify(.user(id: "B"))
        XCTAssertEqual(warnings(), start)
    }

    func testAnonymousToUserDoesNotWarn() async {
        let start = warnings()
        _ = try? await ZeroSettle.shared.identify(.anonymous)
        _ = try? await ZeroSettle.shared.identify(.user(id: "B"))
        XCTAssertEqual(warnings(), start)
    }

    func testUserToAnonymousToOtherUserDoesNotWarn() async {
        let start = warnings()
        _ = try? await ZeroSettle.shared.identify(.user(id: "A"))
        _ = try? await ZeroSettle.shared.identify(.anonymous)
        _ = try? await ZeroSettle.shared.identify(.user(id: "B"))
        XCTAssertEqual(warnings(), start)
    }
}
