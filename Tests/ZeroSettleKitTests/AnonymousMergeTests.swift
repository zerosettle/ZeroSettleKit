import XCTest
@testable import ZeroSettleKit

@MainActor
final class AnonymousMergeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubbedSDK.setUp()
    }

    override func tearDown() {
        StubbedSDK.tearDown()
        super.tearDown()
    }

    private var pending: [String: String]? {
        UserDefaults.standard.data(forKey: StubbedSDK.pendingLinkKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }

    private func linkRequests() -> [StubURLProtocol.Recorded] {
        StubURLProtocol.requests(matching: "identity-link")
    }

    func testNewMintHasPrefixAndLowercaseUUID() {
        let id = ZeroSettle.shared.analyticsUserId
        XCTAssertTrue(id.hasPrefix("zs_anon_"))
        let rest = String(id.dropFirst("zs_anon_".count))
        XCTAssertNotNil(UUID(uuidString: rest))
        XCTAssertEqual(rest, rest.lowercased())
    }

    func testStoredBareUUIDIsKept() {
        let bare = UUID().uuidString.lowercased()
        UserDefaults.standard.set(bare, forKey: StubbedSDK.anonymousKey)
        XCTAssertEqual(ZeroSettle.shared.analyticsUserId, bare)
    }

    func testIdentifyUserWithReservedPrefixThrows() async {
        do {
            _ = try await ZeroSettle.shared.identify(.user(id: "ZS_ANON_abc"))
            XCTFail("expected invalidUserId")
        } catch {
            XCTAssertEqual(error as? ZeroSettleError, .invalidUserId)
        }
        XCTAssertTrue(linkRequests().isEmpty)
    }

    func testMergedClearsPendingPairAndStoredAnonymousId() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        StubURLProtocol.identityLinkBody = #"{"status": "merged", "reconciliation_id": 4}"#

        // The pair is on disk when the request goes out.
        let seen = expectation(description: "link sent")
        nonisolated(unsafe) var pairAtRequest: [String: String]?
        StubURLProtocol.onRequest = { path in
            if path.contains("identity-link") {
                pairAtRequest = UserDefaults.standard.data(forKey: "zerosettle.pending_identity_link")
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
                seen.fulfill()
            }
        }
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))
        await fulfillment(of: [seen], timeout: 5)

        XCTAssertEqual(pairAtRequest, ["from": anon, "into": "acct-1"])
        let body = try XCTUnwrap(linkRequests().first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["previous_user_id"] as? String, anon)
        XCTAssertEqual(json["user_id"] as? String, "acct-1")
        XCTAssertNil(pending)
        XCTAssertNil(UserDefaults.standard.string(forKey: StubbedSDK.anonymousKey))
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "acct-1")
    }

    func testPairKeptOnNetworkErrorAndIdentifyStillSucceeds() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        StubURLProtocol.identityLinkNetworkFailure = true

        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))

        XCTAssertEqual(pending, ["from": anon, "into": "acct-1"])
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "acct-1")
        XCTAssertEqual(linkRequests().count, 1)
    }

    func testTimeoutKeepsPairIdentifyReturnsAndRequestUsesFiveSeconds() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        StubURLProtocol.identityLinkTimesOut = true

        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))

        XCTAssertEqual(StubURLProtocol.identityLinkTimeout, 5)
        XCTAssertEqual(pending, ["from": anon, "into": "acct-1"])
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "acct-1")
    }

    func testSettlingDoesNotClearANewerPairWrittenMidFlight() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        StubURLProtocol.identityLinkBody = #"{"status": "merged"}"#
        let newer = #"{"from":"zs_anon_other","into":"acct-2"}"#
        StubURLProtocol.onRequest = { path in
            if path.contains("identity-link") {
                UserDefaults.standard.set(Data(newer.utf8), forKey: "zerosettle.pending_identity_link")
            }
        }

        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))

        XCTAssertEqual(pending, ["from": "zs_anon_other", "into": "acct-2"])
    }

    func testIdentifyWaitsForARunningConfigureTimeAttempt() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        let pair = #"{"from":"\#(anon)","into":"acct-1"}"#
        UserDefaults.standard.set(Data(pair.utf8), forKey: StubbedSDK.pendingLinkKey)
        StubURLProtocol.identityLinkBody = #"{"status": "merged"}"#
        StubURLProtocol.identityLinkDelay = 0.4

        let background = Task { await ZeroSettle.shared.retryPendingIdentityLink() }
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))

        // The link had landed before identify returned, and it was not sent twice.
        XCTAssertNil(pending)
        XCTAssertEqual(linkRequests().count, 1)
        _ = await background.value
    }

    func testTransientFailureOverwritesOlderPairAndSkipsSecondAttempt() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        let older = #"{"from":"\#(anon)","into":"acct-1"}"#
        UserDefaults.standard.set(Data(older.utf8), forKey: StubbedSDK.pendingLinkKey)
        StubURLProtocol.identityLinkNetworkFailure = true

        _ = try await ZeroSettle.shared.identify(.user(id: "acct-2"))

        XCTAssertEqual(pending, ["from": anon, "into": "acct-2"])
        XCTAssertEqual(linkRequests().count, 1)
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "acct-2")
    }

    func testTotalDeadlineCapsAHangingRequest() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        StubURLProtocol.identityLinkHangs = true
        Backend.identityLinkTimeoutSeconds = 0.3
        defer { Backend.identityLinkTimeoutSeconds = 5 }

        let start = Date()
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))

        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(pending, ["from": anon, "into": "acct-1"])
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "acct-1")
    }

    func testPairKeptOnServerErrorAndRateLimit() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        StubURLProtocol.identityLinkStatusCode = 503
        StubURLProtocol.identityLinkBody = "{}"
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))
        XCTAssertNotNil(pending)

        StubURLProtocol.identityLinkStatusCode = 429
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))
        XCTAssertNotNil(pending)
    }

    func testPendingPairRetriedOnNextIdentifyAndCleared() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        let anon = try XCTUnwrap(ZeroSettle.shared.currentUserId)
        StubURLProtocol.identityLinkNetworkFailure = true
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))
        XCTAssertNotNil(pending)

        StubURLProtocol.identityLinkNetworkFailure = false
        StubURLProtocol.identityLinkBody = #"{"status": "switched"}"#
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))

        XCTAssertNil(pending)
        XCTAssertEqual(linkRequests().count, 2)
        let body = try XCTUnwrap(linkRequests().last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["previous_user_id"] as? String, anon)
    }

    func testClientErrorIsFinalAndClearsPair() async throws {
        _ = try await ZeroSettle.shared.identify(.anonymous)
        StubURLProtocol.identityLinkStatusCode = 400
        StubURLProtocol.identityLinkBody = #"{"error": {"code": "invalid_user_id"}}"#

        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))

        XCTAssertNil(pending)
        XCTAssertNil(UserDefaults.standard.string(forKey: StubbedSDK.anonymousKey))
    }

    func testBareUUIDAnonymousIdIsNotLinked() async throws {
        UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: StubbedSDK.anonymousKey)
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))
        XCTAssertTrue(linkRequests().isEmpty)
        XCTAssertNil(pending)
    }

    func testIdentifyUserWithoutAnonymousIdMakesNoLinkCall() async throws {
        _ = try await ZeroSettle.shared.identify(.user(id: "acct-1"))
        XCTAssertTrue(linkRequests().isEmpty)
    }

    func testMapIdentityLinkResponse() throws {
        func map(_ code: Int, _ body: String, _ headers: [String: String] = [:]) throws -> IdentityLinkStatus {
            try Backend.mapIdentityLinkResponse(statusCode: code, headers: headers, body: Data(body.utf8))
        }
        XCTAssertEqual(try map(200, #"{"status":"merged"}"#), .merged)
        XCTAssertEqual(try map(200, #"{"status":"switched"}"#), .switched)
        XCTAssertEqual(try map(200, #"{"status":"future_value"}"#), .skipped)
        XCTAssertEqual(try map(200, "{}"), .skipped)
        XCTAssertThrowsError(try map(429, "{}", ["Retry-After": "7"])) {
            XCTAssertEqual($0 as? ZeroSettleError, .rateLimited(retryAfter: 7))
        }
        XCTAssertThrowsError(try map(400, #"{"error":{"code":"invalid_user_id"}}"#))
    }
}
