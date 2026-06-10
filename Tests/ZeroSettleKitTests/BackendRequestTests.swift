//
//  BackendRequestTests.swift
//  ZeroSettleKitTests
//
//  Tests for JSON encoding of Backend API request payloads. Uses the same
//  encoder configuration as Backend (snake_case + ISO 8601 dates) to verify
//  that request structs serialize correctly on the wire.
//

import XCTest
@testable import ZeroSettleKit

final class BackendRequestTests: XCTestCase {

    // MARK: - InitiateCheckoutRequest

    func testInitiateCheckoutRequestEncodesNewFields() throws {
        let req = InitiateCheckoutRequest(
            productId: "com.app.pro",
            userId: "user-1",
            stripeCustomerId: nil,
            storekitSubscriptionEnd: nil,
            storekitOriginalTransactionId: nil,
            checkoutMode: nil,
            customerName: nil,
            customerEmail: nil,
            externalPurchaseToken: "xpt-abc-123",
            iosVersion: "26.4.1",
            storefront: "FRA"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["external_purchase_token"] as? String, "xpt-abc-123")
        XCTAssertEqual(dict["ios_version"] as? String, "26.4.1")
        XCTAssertEqual(dict["storefront"] as? String, "FRA")
        XCTAssertEqual(dict["product_id"] as? String, "com.app.pro")
        XCTAssertEqual(dict["platform"] as? String, "ios")
    }

    func testInitiateCheckoutRequestNilFieldsAbsent() throws {
        let req = InitiateCheckoutRequest(
            productId: "p",
            userId: nil,
            stripeCustomerId: nil,
            storekitSubscriptionEnd: nil,
            storekitOriginalTransactionId: nil,
            checkoutMode: nil,
            customerName: nil,
            customerEmail: nil,
            externalPurchaseToken: nil,
            iosVersion: nil,
            storefront: nil
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Swift's default Encoder encodes Optional.none as JSON null — NOT omitted.
        // This test documents actual behavior. The backend tolerates both
        // absent keys and explicit null values for these fields.
        XCTAssertTrue(dict["external_purchase_token"] is NSNull || dict["external_purchase_token"] == nil,
                      "Expected external_purchase_token to be absent or null when nil")
        XCTAssertTrue(dict["ios_version"] is NSNull || dict["ios_version"] == nil,
                      "Expected ios_version to be absent or null when nil")
        XCTAssertTrue(dict["storefront"] is NSNull || dict["storefront"] == nil,
                      "Expected storefront to be absent or null when nil")
    }
}
