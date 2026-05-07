//
//  ConfigurationTests.swift
//  ZeroSettleKitTests
//
import XCTest
@testable import ZeroSettleKit

final class ConfigurationTests: XCTestCase {
    func testSdkVersionIsExposed() {
        XCTAssertEqual(Configuration.sdkVersion, "1.3.1")
    }

    func testSdkVersionParseable() {
        // Sanity: matches semver "MAJOR.MINOR.PATCH"
        let parts = Configuration.sdkVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "sdkVersion should be MAJOR.MINOR.PATCH semver")
        for p in parts {
            XCTAssertNotNil(Int(p), "each part should be numeric: \(p)")
        }
    }
}
