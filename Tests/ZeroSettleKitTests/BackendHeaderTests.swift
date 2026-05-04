//
//  BackendHeaderTests.swift
//  ZeroSettleKitTests
//
//  Tests that Backend's auth headers include both X-ZeroSettle-Key and the
//  X-ZS-SDK-Version header introduced for the deferred-mode pivot.
//
//  Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §3.1
//

import XCTest
@testable import ZeroSettleKit

final class BackendHeaderTests: XCTestCase {
    func testAuthHeadersIncludeSdkVersion() {
        // Construct Backend the same way existing tests do — match the actual
        // initializer signature in Sources/ZeroSettleKit/Backend/Backend.swift:29
        let backend = Backend(
            baseURL: URL(string: "https://api.zerosettle.io/v1/")!,
            publishableKey: "zs_pk_test_xyz"
        )
        let headers = backend.testAuthHeaders  // see Step 3 — small test-only accessor
        XCTAssertEqual(headers["X-ZeroSettle-Key"], "zs_pk_test_xyz")
        XCTAssertEqual(headers["X-ZS-SDK-Version"], Configuration.sdkVersion)
        XCTAssertEqual(headers["X-ZS-SDK-Version"], "1.3.0")
    }
}
