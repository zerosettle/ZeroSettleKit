import XCTest
@testable import ZeroSettleKit

final class OfferImpressionReporterTests: XCTestCase {
    @MainActor func testResolvesExplicitOverCurrent() {
        ZeroSettle.shared.setCurrentOfferForTesting(ResolvedOffer(productId: "auto", variantId: nil, flowType: "migration"))
        let r = OfferImpressionReporter()
        let resolved = r.resolve(productId: "explicit", variantId: 3, flowType: "upgrade")
        XCTAssertEqual(resolved?.productId, "explicit")
        XCTAssertEqual(resolved?.variantId, 3)
        XCTAssertEqual(resolved?.flowType, "upgrade")
    }
    @MainActor func testFallsBackToCurrentOffer() {
        ZeroSettle.shared.setCurrentOfferForTesting(ResolvedOffer(productId: "auto", variantId: 9, flowType: "migration"))
        let r = OfferImpressionReporter()
        let resolved = r.resolve(productId: nil, variantId: nil, flowType: nil)
        XCTAssertEqual(resolved?.productId, "auto")
        XCTAssertEqual(resolved?.variantId, 9)
    }
    @MainActor func testNilWhenNothingResolvable() {
        ZeroSettle.shared.setCurrentOfferForTesting(nil)
        let r = OfferImpressionReporter()
        XCTAssertNil(r.resolve(productId: nil, variantId: nil, flowType: nil))
    }
    @MainActor func testDedupSameKeyReportsOnce() {
        let r = OfferImpressionReporter()
        let o = ResolvedOffer(productId: "p", variantId: nil, flowType: "migration")
        XCTAssertTrue(r.shouldReportForTesting(o))
        XCTAssertFalse(r.shouldReportForTesting(o))
    }
}
