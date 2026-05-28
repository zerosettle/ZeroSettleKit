import XCTest
@testable import ZeroSettleKit

final class SessionIdTests: XCTestCase {
    @MainActor
    func testSessionIdIsNonEmptyAndStableAcrossReads() {
        let a = ZeroSettle.shared.sessionId
        let b = ZeroSettle.shared.sessionId
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b)
    }

    @MainActor
    func testRegenerateSessionIdChangesIt() {
        let before = ZeroSettle.shared.sessionId
        ZeroSettle.shared.regenerateSessionId()
        XCTAssertNotEqual(before, ZeroSettle.shared.sessionId)
        XCTAssertFalse(ZeroSettle.shared.sessionId.isEmpty)
    }
}
