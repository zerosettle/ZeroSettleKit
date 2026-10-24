import XCTest
@testable import ZeroSettleKit

final class FunnelEventEnvironmentTests: XCTestCase {
    private func encode(_ req: TrackFunnelEventRequest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(req)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testEncodesEnvironmentWhenSet() throws {
        let dict = try encode(TrackFunnelEventRequest(
            eventType: "paywall_viewed", userId: "u", productId: "p",
            screenName: nil, metadata: nil, environment: "Sandbox"))
        XCTAssertEqual(dict["environment"] as? String, "Sandbox")
        XCTAssertEqual(dict["user_id"] as? String, "u")
        XCTAssertEqual(dict["event_type"] as? String, "paywall_viewed")
    }

    func testOmitsEnvironmentWhenNil() throws {
        let dict = try encode(TrackFunnelEventRequest(
            eventType: "paywall_viewed", userId: "u", productId: "p",
            screenName: nil, metadata: nil))
        XCTAssertNil(dict["environment"])
        XCTAssertFalse(dict.keys.contains("environment"))
    }
}
