//
//  LoggerTests.swift
//  ZeroSettleCoreTests
//

import XCTest
@testable import ZeroSettleCore

final class LoggerTests: XCTestCase {
    func testLoggerCompiles() {
        ZSLogger.info("Test message", category: .general)
    }
}
