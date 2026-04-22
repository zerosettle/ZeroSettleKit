//
//  EntitlementMergeTests.swift
//  ZeroSettleKitTests
//

import XCTest
@testable import ZeroSettleKit

final class EntitlementMergeTests: XCTestCase {

    private func makeEntitlement(
        id: String,
        productId: String = "test.product",
        source: Entitlement.Source = .webCheckout
    ) -> Entitlement {
        Entitlement(
            id: id,
            productId: productId,
            source: source,
            isActive: true,
            purchasedAt: Date()
        )
    }

    func testPreservesLocalFallbackMissingFromFresh() {
        let localFallback = makeEntitlement(id: "web_txn_abc")
        let result = EntitlementMerge.preservingLocalFallbacks(
            fresh: [],
            prior: [localFallback]
        )
        XCTAssertEqual(result.map(\.id), ["web_txn_abc"])
    }

    func testDoesNotDuplicateLocalFallbackAlreadyInFresh() {
        let localFallback = makeEntitlement(id: "web_txn_abc")
        let result = EntitlementMerge.preservingLocalFallbacks(
            fresh: [localFallback],
            prior: [localFallback]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "web_txn_abc")
    }

    func testDropsPriorEntitlementsWithoutLocalFallbackPrefix() {
        // A prior entitlement with a non-web_ id represents a stale
        // backend-sourced row — the fresh list is authoritative for those.
        let stale = makeEntitlement(id: "123")
        let result = EntitlementMerge.preservingLocalFallbacks(
            fresh: [],
            prior: [stale]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testPreservesMultipleLocalFallbacks() {
        let f1 = makeEntitlement(id: "web_txn_one")
        let f2 = makeEntitlement(id: "web_txn_two")
        let result = EntitlementMerge.preservingLocalFallbacks(
            fresh: [],
            prior: [f1, f2]
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(["web_txn_one", "web_txn_two"]))
    }

    func testFreshEntitlementsComeFirst() {
        let freshBackend = makeEntitlement(id: "456")
        let localFallback = makeEntitlement(id: "web_txn_abc")
        let result = EntitlementMerge.preservingLocalFallbacks(
            fresh: [freshBackend],
            prior: [localFallback]
        )
        XCTAssertEqual(result.map(\.id), ["456", "web_txn_abc"])
    }

    func testMixedPriorList() {
        let localFallback = makeEntitlement(id: "web_txn_abc")
        let stale = makeEntitlement(id: "999")
        let freshBackend = makeEntitlement(id: "456")
        let result = EntitlementMerge.preservingLocalFallbacks(
            fresh: [freshBackend],
            prior: [localFallback, stale]
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(["456", "web_txn_abc"]))
    }

    func testEmptyInputsReturnEmpty() {
        let result = EntitlementMerge.preservingLocalFallbacks(
            fresh: [],
            prior: []
        )
        XCTAssertTrue(result.isEmpty)
    }
}
