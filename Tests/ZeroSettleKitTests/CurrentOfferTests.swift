import XCTest
@testable import ZeroSettleKit

final class CurrentOfferTests: XCTestCase {
    @MainActor
    func testCurrentOfferSetAndClear() {
        ZeroSettle.shared.setCurrentOfferForTesting(ResolvedOffer(productId: "com.app.pro", variantId: 7, flowType: "migration"))
        XCTAssertEqual(ZeroSettle.shared.currentOffer?.productId, "com.app.pro")
        XCTAssertEqual(ZeroSettle.shared.currentOffer?.variantId, 7)
        XCTAssertEqual(ZeroSettle.shared.currentOffer?.flowType, "migration")
        ZeroSettle.shared.setCurrentOfferForTesting(nil)
        XCTAssertNil(ZeroSettle.shared.currentOffer)
    }
}
