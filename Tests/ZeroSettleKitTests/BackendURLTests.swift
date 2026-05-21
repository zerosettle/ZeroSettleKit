//
//  BackendURLTests.swift
//  ZeroSettleKitTests
//
//  Verifies apiURL() versions every request under /v1, whether the base URL
//  is the bare API origin or already ends in /v1 — so `setBaseUrlOverride`
//  works with the same (origin) value the Android SDK takes. Regression test
//  for iOS hitting `/iap/products/` (no /v1) when given an origin base URL.
//

import XCTest
@testable import ZeroSettleKit

final class BackendURLTests: XCTestCase {
    private func backend(_ base: String) -> Backend {
        Backend(baseURL: URL(string: base)!, publishableKey: "zs_pk_test_xyz")
    }

    func testApiURLVersionsABareOrigin() {
        // A bare origin — what setBaseUrlOverride and the Android SDK use —
        // must still produce a /v1-versioned path.
        let url = backend("https://api.zerosettle.io").apiURL("iap/products/")
        XCTAssertEqual(
            url.absoluteString, "https://api.zerosettle.io/v1/iap/products/")
    }

    func testApiURLVersionsAnNgrokOrigin() {
        let url = backend("https://api.zerosettle.ngrok.app")
            .apiURL("iap/entitlements/")
        XCTAssertEqual(
            url.absoluteString,
            "https://api.zerosettle.ngrok.app/v1/iap/entitlements/")
    }

    func testApiURLDoesNotDoubleVersionABaseAlreadyEndingInV1() {
        // A base URL already ending in /v1 must not become /v1/v1/.
        for base in ["https://api.zerosettle.io/v1",
                     "https://api.zerosettle.io/v1/"] {
            let url = backend(base).apiURL("iap/products/")
            XCTAssertEqual(
                url.absoluteString, "https://api.zerosettle.io/v1/iap/products/",
                "base \(base) should normalize to a single /v1")
        }
    }
}
