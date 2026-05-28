import XCTest
@testable import ZeroSettleKit

final class OfferViewedRequestTests: XCTestCase {
    private func encodeToDict(_ req: TrackOfferViewedRequest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(req)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testEncodesAllFieldsSnakeCase() throws {
        let req = TrackOfferViewedRequest(
            userId: "user-1", productId: "com.app.pro",
            sessionId: "sess-1", variantId: 7, flowType: "migration"
        )
        let dict = try encodeToDict(req)
        XCTAssertEqual(dict["user_id"] as? String, "user-1")
        XCTAssertEqual(dict["product_id"] as? String, "com.app.pro")
        XCTAssertEqual(dict["session_id"] as? String, "sess-1")
        XCTAssertEqual(dict["variant_id"] as? Int, 7)
        XCTAssertEqual(dict["flow_type"] as? String, "migration")
    }

    func testNilVariantIdIsOmitted() throws {
        let req = TrackOfferViewedRequest(
            userId: "u", productId: "p", sessionId: "s", variantId: nil, flowType: "migration"
        )
        let dict = try encodeToDict(req)
        XCTAssertNil(dict["variant_id"], "nil variant_id must be omitted so the backend applies its NO_VARIANT sentinel")
    }
}
