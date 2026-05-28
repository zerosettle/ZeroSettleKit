import XCTest
import CoreGraphics
@testable import ZeroSettleKit

final class BannerVisibilityTests: XCTestCase {
    let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)

    func testFullyInsideIsFullyVisible() {
        let card = CGRect(x: 16, y: 300, width: 358, height: 120)
        XCTAssertEqual(BannerVisibility.visibleFraction(of: card, in: viewport), 1.0, accuracy: 0.001)
        XCTAssertTrue(BannerVisibility.isOnScreen(card, in: viewport))
    }

    func testHalfBelowBottomIsHalfVisible() {
        let card = CGRect(x: 16, y: 794, width: 358, height: 100)
        XCTAssertEqual(BannerVisibility.visibleFraction(of: card, in: viewport), 0.5, accuracy: 0.001)
        XCTAssertTrue(BannerVisibility.isOnScreen(card, in: viewport, threshold: 0.5))
    }

    func testJustUnderThresholdIsNotOnScreen() {
        let card = CGRect(x: 16, y: 804, width: 358, height: 100)
        XCTAssertFalse(BannerVisibility.isOnScreen(card, in: viewport, threshold: 0.5))
    }

    func testFullyAboveIsZero() {
        let card = CGRect(x: 16, y: -200, width: 358, height: 120)
        XCTAssertEqual(BannerVisibility.visibleFraction(of: card, in: viewport), 0.0, accuracy: 0.001)
        XCTAssertFalse(BannerVisibility.isOnScreen(card, in: viewport))
    }

    func testZeroHeightIsZero() {
        let card = CGRect(x: 16, y: 300, width: 358, height: 0)
        XCTAssertEqual(BannerVisibility.visibleFraction(of: card, in: viewport), 0.0, accuracy: 0.001)
    }
}
