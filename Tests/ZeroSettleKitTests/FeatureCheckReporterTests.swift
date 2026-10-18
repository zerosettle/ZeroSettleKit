//
//  FeatureCheckReporterTests.swift
//  ZeroSettleKitTests
//
//  The reporter that tells the backend which feature keys the app checks, and the
//  Backend request it sends.
//

import XCTest
@testable import ZeroSettleKit

private final class FakeFeatureSender: FeatureCheckSender, @unchecked Sendable {
    let publishableKey: String
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var error: Error?
    private var holdNext = false
    private var holding: CheckedContinuation<Void, Never>?

    init(publishableKey: String = "zs_pk_test_a") { self.publishableKey = publishableKey }

    var batches: [[String]] { lock.withLock { recorded } }
    var isHolding: Bool { lock.withLock { holding != nil } }
    var flattened: [String] { batches.flatMap { $0 } }

    func failWith(_ error: Error?) { lock.withLock { self.error = error } }
    func holdNextSend() { lock.withLock { holdNext = true } }
    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let held = holding
            holding = nil
            return held
        }
        continuation?.resume()
    }

    func send(keys: [String]) async throws {
        lock.withLock { recorded.append(keys) }
        let shouldHold = lock.withLock { () -> Bool in
            let hold = holdNext
            holdNext = false
            return hold
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { holding = continuation }
            }
        }
        if let error = lock.withLock({ error }) { throw error }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
final class FeatureCheckReporterTests: XCTestCase {

    private var clock: TestClock!
    private var reporter: FeatureCheckReporter!

    override func setUp() async throws {
        clock = TestClock()
        let clock = self.clock!
        reporter = FeatureCheckReporter(delay: 0, backoff: 60, now: { clock.now })
    }

    private func apiError(_ status: Int) -> Error {
        ZeroSettleError.apiError(APIErrorDetail(statusCode: status, serverMessage: nil, serverCode: nil, underlyingError: nil))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testSendsEachKeyOnce() async {
        let sender = FakeFeatureSender()
        reporter.reset(sender: sender)
        reporter.note("a")
        reporter.note("b")
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        reporter.note("a")
        reporter.note("b")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches, [["a", "b"]])
    }

    func testBatchesFiftyPerRequest() async {
        let sender = FakeFeatureSender()
        reporter.reset(sender: sender)
        let keys = (0..<120).map { "k\($0)" }
        keys.forEach(reporter.note)
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches.map(\.count), [50, 50, 20])
        XCTAssertEqual(sender.flattened, keys)
    }

    func testSkipsEmptyAndLongKeys() async {
        let sender = FakeFeatureSender()
        reporter.reset(sender: sender)
        let tooLong = String(repeating: "a", count: 65)
        let emoji = String(repeating: "\u{1F600}", count: 64)
        reporter.note("")
        reporter.note(tooLong)
        reporter.note(emoji)
        await reporter.waitForIdleForTesting()
        reporter.note(tooLong)
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches, [[emoji]])
    }

    func testNetworkErrorRetriesAfterBackoff() async {
        let sender = FakeFeatureSender()
        reporter.reset(sender: sender)
        sender.failWith(URLError(.notConnectedToInternet))
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches.count, 1)

        clock.advance(59)
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches.count, 1, "no send before the 60 second backoff passes")

        clock.advance(2)
        sender.failWith(nil)
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches, [["a"], ["a"]])

        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches.count, 2, "sent keys are not sent again")
    }

    func testServerErrorBacksOffAndKeepsKeysPending() async {
        let sender = FakeFeatureSender()
        reporter.reset(sender: sender)
        sender.failWith(apiError(500))
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        clock.advance(61)
        sender.failWith(nil)
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches, [["a"], ["a"]])
    }

    func testBadRequestIsNotRetried() async {
        for status in [400, 401, 403] {
            let sender = FakeFeatureSender()
            reporter.reset(sender: sender)
            sender.failWith(apiError(status))
            reporter.note("a")
            await reporter.waitForIdleForTesting()
            clock.advance(120)
            reporter.note("a")
            await reporter.waitForIdleForTesting()
            XCTAssertEqual(sender.batches, [["a"]], "status \(status)")
        }
    }

    func testResetSendsAgain() async {
        let first = FakeFeatureSender(publishableKey: "zs_pk_test_a")
        reporter.reset(sender: first)
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        let second = FakeFeatureSender(publishableKey: "zs_pk_test_b")
        reporter.reset(sender: second)
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(first.batches, [["a"]])
        XCTAssertEqual(second.batches, [["a"]])
        XCTAssertEqual(second.publishableKey, "zs_pk_test_b")
    }

    func testResetClearsBackoff() async {
        let first = FakeFeatureSender()
        reporter.reset(sender: first)
        first.failWith(URLError(.timedOut))
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        let second = FakeFeatureSender()
        reporter.reset(sender: second)
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(second.batches, [["a"]])
    }

    func testLateResultAfterResetChangesNothing() async {
        let old = FakeFeatureSender(publishableKey: "zs_pk_test_old")
        reporter.reset(sender: old)
        old.holdNextSend()
        (0..<120).forEach { reporter.note("k\($0)") }
        await waitUntil { old.isHolding }

        let new = FakeFeatureSender(publishableKey: "zs_pk_test_new")
        reporter.reset(sender: new)
        reporter.note("A")
        old.release()
        await reporter.waitForIdleForTesting()
        reporter.note("B")
        await reporter.waitForIdleForTesting()

        XCTAssertEqual(old.batches.count, 1)
        XCTAssertEqual(new.flattened.sorted(), ["A", "B"])
    }

    func testLateFailureAfterResetSetsNoBackoff() async {
        let old = FakeFeatureSender()
        reporter.reset(sender: old)
        old.holdNextSend()
        old.failWith(URLError(.notConnectedToInternet))
        reporter.note("a")
        await waitUntil { old.isHolding }

        let new = FakeFeatureSender()
        reporter.reset(sender: new)
        old.release()
        await reporter.waitForIdleForTesting()
        reporter.note("b")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(new.batches, [["b"]])
    }

    func testOldFlushDoesNotClearNewGenerationFlag() async {
        let old = FakeFeatureSender(publishableKey: "zs_pk_test_old")
        reporter.reset(sender: old)
        old.holdNextSend()
        reporter.note("old")
        await waitUntil { old.isHolding }

        let new = FakeFeatureSender(publishableKey: "zs_pk_test_new")
        new.holdNextSend()
        reporter.reset(sender: new)
        reporter.note("A")
        await waitUntil { new.isHolding }

        old.release()
        for _ in 0..<20 { await Task.yield() }
        reporter.note("C")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(new.batches, [["A"]], "no second flush while the first is in flight")

        new.release()
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(new.batches, [["A"], ["C"]])
        XCTAssertEqual(old.batches.count, 1)
    }

    func testNothingSentBeforeConfigure() async {
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        let sender = FakeFeatureSender()
        reporter.reset(sender: sender)
        await reporter.waitForIdleForTesting()
        XCTAssertTrue(sender.batches.isEmpty, "a key noted before configure is dropped")
        reporter.note("a")
        await reporter.waitForIdleForTesting()
        XCTAssertEqual(sender.batches, [["a"]])
    }

    func testTwoSecondDelayIsTheDefault() {
        // The default delay and backoff are the documented 2 and 60 seconds; tests inject zero.
        let mirror = Mirror(reflecting: FeatureCheckReporter())
        XCTAssertEqual(mirror.children.first { $0.label == "delay" }?.value as? TimeInterval, 2)
        XCTAssertEqual(mirror.children.first { $0.label == "backoff" }?.value as? TimeInterval, 60)
    }
}

@MainActor
final class FeatureCheckConfigureTests: XCTestCase {
    func testHasAccessNotesTheKeyAndBalanceDoesNot() async {
        let zs = ZeroSettle.shared
        let saved = zs.currentConfig
        defer { zs.setConfigForTesting(saved) }
        let sender = FakeFeatureSender()
        zs.featureCheckReporter.reset(sender: sender)
        defer { zs.featureCheckReporter.reset(sender: FakeFeatureSender()) }
        _ = zs.balance("credits")
        _ = zs.plan
        _ = zs.access
        _ = zs.hasAccess("dark_mode")
        _ = zs.value("quality")
        await zs.featureCheckReporter.waitForIdleForTesting()
        XCTAssertEqual(sender.flattened, ["dark_mode", "quality"])
    }
}

@MainActor
final class FeatureCheckConfigureResetTests: XCTestCase {
    func testConfigureResetsReporterOnlyOnKeyOrURLChange() {
        let zs = ZeroSettle.shared
        let savedConfig = zs.currentConfig
        let savedOverride = ZeroSettle.baseURLOverride
        defer {
            ZeroSettle.baseURLOverride = savedOverride
            zs.setConfigForTesting(savedConfig)
            zs.featureCheckReporter.reset(sender: FakeFeatureSender())
        }
        ZeroSettle.baseURLOverride = URL(string: "https://one.test")!
        zs.configure(.init(publishableKey: "zs_pk_test_cfg_a"))
        let first = zs.featureCheckReporter.generationForTesting

        zs.configure(.init(publishableKey: "zs_pk_test_cfg_a"))
        XCTAssertEqual(zs.featureCheckReporter.generationForTesting, first, "same key and URL does not reset")

        zs.configure(.init(publishableKey: "zs_pk_test_cfg_b"))
        XCTAssertEqual(zs.featureCheckReporter.generationForTesting, first + 1, "a new key resets")

        ZeroSettle.baseURLOverride = URL(string: "https://two.test")!
        zs.configure(.init(publishableKey: "zs_pk_test_cfg_b"))
        XCTAssertEqual(zs.featureCheckReporter.generationForTesting, first + 2, "a new base URL alone resets")
    }
}

final class FeatureCheckedRequestTests: XCTestCase {
    func testReportFeaturesCheckedRequest() async throws {
        CapturingURLProtocol.reset(status: 204)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let backend = Backend(baseURL: URL(string: "https://example.test")!, publishableKey: "zs_pk_test_req", session: URLSession(configuration: config))
        try await backend.reportFeaturesChecked(keys: ["dark_mode", "quality"])
        let request = try XCTUnwrap(CapturingURLProtocol.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/iap/features/checked/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-ZeroSettle-Key"), "zs_pk_test_req")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(CapturingURLProtocol.body)) as? [String: Any]
        XCTAssertEqual(json?["keys"] as? [String], ["dark_mode", "quality"])
        XCTAssertEqual(json?.count, 1)
    }

    func testRejectedKeySurfacesStatusCode() async throws {
        CapturingURLProtocol.reset(status: 403)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let backend = Backend(baseURL: URL(string: "https://example.test")!, publishableKey: "zs_pk_test_req", session: URLSession(configuration: config))
        do {
            try await backend.reportFeaturesChecked(keys: ["a"])
            XCTFail("expected a throw")
        } catch ZeroSettleError.apiError(let detail) {
            XCTAssertEqual(detail.statusCode, 403)
        }
    }
}

final class CapturingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var body: Data?
    nonisolated(unsafe) static var status = 204

    static func reset(status: Int) {
        request = nil
        body = nil
        self.status = status
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        if let data = request.httpBody {
            Self.body = data
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.body = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
