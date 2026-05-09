import XCTest
@testable import ZeroSettleKit

@MainActor
final class ZSOfferManagerActiveAccessorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Reset shared singleton state between tests
        ZeroSettle.shared._resetForTesting()
    }

    func test_activeOfferManager_returnsNilWhenNeverInstantiated() {
        XCTAssertNil(ZeroSettle.shared._activeOfferManagerForBookkeeping)
    }

    func test_activeOfferManager_returnsInstanceAfterFirstFactoryCall() {
        _ = ZeroSettle.shared.offerManager()
        XCTAssertNotNil(ZeroSettle.shared._activeOfferManagerForBookkeeping)
    }

    func test_activeOfferManager_doesNotInstantiateOnRead() {
        _ = ZeroSettle.shared._activeOfferManagerForBookkeeping
        // Reading the accessor must not have created a manager
        XCTAssertNil(ZeroSettle.shared._activeOfferManagerForBookkeeping)
    }

    func test_activeOfferManager_returnsSameInstanceAcrossCalls() {
        let first = ZeroSettle.shared.offerManager()
        let peeked = ZeroSettle.shared._activeOfferManagerForBookkeeping
        XCTAssertTrue(first === peeked)
    }
}
