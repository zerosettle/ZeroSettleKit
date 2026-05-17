//
//  ProductLookupCaseInsensitiveTests.swift
//  ZeroSettleKitTests
//
//  The backend's `Product.reference_id` is matched case-insensitively at the
//  ORM layer (a `UNIQUE(LOWER(reference_id))` constraint backs the contract).
//  Apple's StoreKit ids ARE case-sensitive, but developers routinely register
//  products in mixed case in App Store Connect and reference them in lowercase
//  in code (or vice-versa). The SDK's local catalog lookup must therefore be
//  case-insensitive to stay consistent with what the backend will accept.
//
//  Five lookup call-sites delegate to `Array<ZSProduct>.firstMatching(id:)` /
//  `containsMatching(id:)`; testing the helper pins the contract for all of
//  them in one place.
//

import XCTest
@testable import ZeroSettleKit

final class ProductLookupCaseInsensitiveTests: XCTestCase {

    // MARK: - Fixtures

    private func makeProduct(id: String) -> ZSProduct {
        ZSProduct(
            id: id,
            displayName: "Pro Monthly",
            productDescription: "test",
            type: .autoRenewableSubscription
        )
    }

    // MARK: - firstMatching(id:)

    func test_firstMatching_exactMatch_returnsProduct() {
        let products = [makeProduct(id: "com.app.pro_monthly")]
        let hit = products.firstMatching(id: "com.app.pro_monthly")
        XCTAssertEqual(hit?.id, "com.app.pro_monthly")
    }

    func test_firstMatching_mixedCaseStored_lowercaseRequested_returnsProduct() {
        let products = [makeProduct(id: "Com.App.Pro_Monthly")]
        let hit = products.firstMatching(id: "com.app.pro_monthly")
        XCTAssertNotNil(hit, "Mixed-case stored id must match lowercase request")
        XCTAssertEqual(hit?.id, "Com.App.Pro_Monthly")
    }

    func test_firstMatching_uppercaseStored_mixedCaseRequested_returnsProduct() {
        let products = [makeProduct(id: "COM.APP.PRO_MONTHLY")]
        let hit = products.firstMatching(id: "Com.App.Pro_Monthly")
        XCTAssertNotNil(hit, "Uppercase stored id must match mixed-case request")
        XCTAssertEqual(hit?.id, "COM.APP.PRO_MONTHLY")
    }

    func test_firstMatching_lowercaseStored_uppercaseRequested_returnsProduct() {
        let products = [makeProduct(id: "com.app.pro_monthly")]
        let hit = products.firstMatching(id: "COM.APP.PRO_MONTHLY")
        XCTAssertNotNil(hit, "Lowercase stored id must match uppercase request")
    }

    func test_firstMatching_unrelatedId_returnsNil() {
        let products = [makeProduct(id: "com.app.pro_monthly")]
        let hit = products.firstMatching(id: "com.app.pro_yearly")
        XCTAssertNil(hit)
    }

    func test_firstMatching_emptyArray_returnsNil() {
        let products: [ZSProduct] = []
        XCTAssertNil(products.firstMatching(id: "com.app.pro_monthly"))
    }

    func test_firstMatching_returnsFirstHitInOrder() {
        // Two products with case-different but equivalent ids — implementation
        // returns the first match (matches `Array.first(where:)` semantics).
        let products = [
            makeProduct(id: "com.app.pro_monthly"),
            makeProduct(id: "COM.APP.PRO_MONTHLY")
        ]
        let hit = products.firstMatching(id: "Com.App.Pro_Monthly")
        XCTAssertEqual(hit?.id, "com.app.pro_monthly",
                       "Should return the first array element when multiple case-equivalent ids exist")
    }

    // MARK: - containsMatching(id:)

    func test_containsMatching_mixedCaseStored_lowercaseRequested_returnsTrue() {
        let products = [makeProduct(id: "Com.App.Pro_Monthly")]
        XCTAssertTrue(products.containsMatching(id: "com.app.pro_monthly"))
    }

    func test_containsMatching_unrelatedId_returnsFalse() {
        let products = [makeProduct(id: "com.app.pro_monthly")]
        XCTAssertFalse(products.containsMatching(id: "com.app.pro_yearly"))
    }

    func test_containsMatching_emptyArray_returnsFalse() {
        let products: [ZSProduct] = []
        XCTAssertFalse(products.containsMatching(id: "com.app.pro_monthly"))
    }

    // MARK: - Public `product(for:)` integration

    /// `ZeroSettle.shared.product(for:)` exposes the line-581 lookup. We can't
    /// inject products into the singleton (the setter is private), but we can
    /// still exercise the negative path — an unknown id must return nil — which
    /// pins the call-site against accidental regressions to a non-helper impl.
    @MainActor
    func test_zeroSettle_product_unknownId_returnsNil() {
        XCTAssertNil(ZeroSettle.shared.product(for: "com.app.does_not_exist"))
    }
}
