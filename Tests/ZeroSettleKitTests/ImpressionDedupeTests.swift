import XCTest
@testable import ZeroSettleKit

final class ImpressionDedupeTests: XCTestCase {
    @MainActor
    func testShouldReportOnlyFirstTimePerKey() {
        let d = ImpressionDedupe()
        XCTAssertTrue(d.shouldReport("s1:-1"))
        XCTAssertFalse(d.shouldReport("s1:-1"))
    }

    @MainActor
    func testDifferentKeysEachReportOnce() {
        let d = ImpressionDedupe()
        XCTAssertTrue(d.shouldReport("s1:-1"))
        XCTAssertTrue(d.shouldReport("s1:7"))
        XCTAssertTrue(d.shouldReport("s2:-1"))
        XCTAssertFalse(d.shouldReport("s1:7"))
    }
}
