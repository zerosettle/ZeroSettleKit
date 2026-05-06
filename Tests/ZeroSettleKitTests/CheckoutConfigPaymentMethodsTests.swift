//
//  CheckoutConfigPaymentMethodsTests.swift
//  ZeroSettleKitTests
//
import XCTest
@testable import ZeroSettleKit

final class CheckoutConfigPaymentMethodsTests: XCTestCase {

    // MARK: - Direct property tests

    func testIsApplePayOnlyTrueForSingleApplePayEntry() {
        let cfg = CheckoutConfig(
            sheetType: .webView,
            isEnabled: true,
            paymentMethods: [PaymentMethodID.applePay]
        )
        XCTAssertTrue(cfg.isApplePayOnly)
    }

    func testIsApplePayOnlyFalseWhenNil() {
        let cfg = CheckoutConfig(
            sheetType: .webView,
            isEnabled: true,
            paymentMethods: nil
        )
        XCTAssertFalse(cfg.isApplePayOnly)
    }

    func testIsApplePayOnlyFalseForMultipleMethods() {
        let cfg = CheckoutConfig(
            sheetType: .webView,
            isEnabled: true,
            paymentMethods: ["apple_pay", "card"]
        )
        XCTAssertFalse(cfg.isApplePayOnly)
    }

    func testIsApplePayOnlyFalseForCardOnly() {
        let cfg = CheckoutConfig(
            sheetType: .webView,
            isEnabled: true,
            paymentMethods: ["card"]
        )
        XCTAssertFalse(cfg.isApplePayOnly)
    }
}

extension CheckoutConfigPaymentMethodsTests {

    // Mirror Backend.swift's decoder configuration so this test covers the
    // wire contract (snake_case → camelCase) end-to-end.
    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    func testWireDecodePaymentMethodsPresent() throws {
        struct Probe: Decodable {
            let paymentMethods: [String]?
        }
        let json = #"{"payment_methods": ["apple_pay"]}"#
        let probe = try decode(Probe.self, from: json)
        XCTAssertEqual(probe.paymentMethods, [PaymentMethodID.applePay])
    }

    func testWireDecodePaymentMethodsAbsent() throws {
        struct Probe: Decodable {
            let paymentMethods: [String]?
        }
        let json = #"{}"#
        let probe = try decode(Probe.self, from: json)
        XCTAssertNil(probe.paymentMethods)
    }
}
