import XCTest
@testable import ZeroSettleKit

/// URLProtocol stub that answers every ZeroSettle request in-process and
/// records what was sent. Registered globally, so it covers `URLSession.shared`.
final class StubURLProtocol: URLProtocol {
    struct Recorded {
        let path: String
        let body: Data
    }

    nonisolated(unsafe) static var recorded: [Recorded] = []
    nonisolated(unsafe) static var reconcileBody = "{}"
    nonisolated(unsafe) static var identityLinkBody = #"{"status": "skipped"}"#
    nonisolated(unsafe) static var identityLinkStatusCode = 200
    /// When true, identity-link requests fail at the transport layer.
    nonisolated(unsafe) static var identityLinkNetworkFailure = false
    /// When true, identity-link requests fail with `URLError.timedOut`.
    nonisolated(unsafe) static var identityLinkTimesOut = false
    /// `timeoutInterval` of the last identity-link request.
    nonisolated(unsafe) static var identityLinkTimeout: TimeInterval?
    /// Seconds to hold an identity-link response back.
    nonisolated(unsafe) static var identityLinkDelay: TimeInterval = 0
    /// When true, identity-link requests never get a response.
    nonisolated(unsafe) static var identityLinkHangs = false
    nonisolated(unsafe) static var onRequest: (@Sendable (String) -> Void)?
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        reconcileBody = "{}"
        identityLinkBody = #"{"status": "skipped"}"#
        identityLinkStatusCode = 200
        identityLinkNetworkFailure = false
        identityLinkTimesOut = false
        identityLinkTimeout = nil
        identityLinkDelay = 0
        identityLinkHangs = false
        onRequest = nil
    }

    static func requests(matching path: String) -> [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.path.contains(path) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.zerosettle.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.recorded.append(Recorded(path: url.path, body: body))
        let reconcile = Self.reconcileBody
        let identityLink = Self.identityLinkBody
        let identityLinkStatus = Self.identityLinkStatusCode
        let identityLinkFails = Self.identityLinkNetworkFailure
        let identityLinkTimesOut = Self.identityLinkTimesOut
        let identityLinkDelay = Self.identityLinkDelay
        let identityLinkHangs = Self.identityLinkHangs
        if url.path.contains("identity-link") { Self.identityLinkTimeout = request.timeoutInterval }
        let callback = Self.onRequest
        Self.lock.unlock()

        if url.path.contains("identity-link") && identityLinkHangs { return }
        if url.path.contains("identity-link") && identityLinkDelay > 0 {
            Thread.sleep(forTimeInterval: identityLinkDelay)
        }
        if url.path.contains("identity-link") && identityLinkTimesOut {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            callback?(url.path)
            return
        }
        if url.path.contains("identity-link") && identityLinkFails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            callback?(url.path)
            return
        }

        var statusCode = 200
        let payload: String
        if url.path.contains("identity-link") { payload = identityLink; statusCode = identityLinkStatus }
        else if url.path.contains("products") { payload = #"{"products": []}"# }
        else if url.path.contains("entitlements") { payload = #"{"entitlements": []}"# }
        else if url.path.contains("reconcile") { payload = reconcile }
        else { payload = "{}" }

        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
        callback?(url.path)
    }

    override func stopLoading() {}
}

/// Configures the SDK explicitly against the stub and restores state after.
@MainActor
enum StubbedSDK {
    static let anonymousKey = "zerosettle.anonymous_session_uuid"
    static let pendingLinkKey = "zerosettle.pending_identity_link"

    static func setUp() {
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
        ZeroSettle.baseURLOverride = URL(string: "https://stub.zerosettle.test")
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonymousKey)
        UserDefaults.standard.removeObject(forKey: pendingLinkKey)
        ZeroSettle.shared.configure(.init(
            publishableKey: "zs_pk_test_stubbedIdentity",
            syncStoreKitTransactions: false,
            preloadCheckout: false
        ))
    }

    static func tearDown() {
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonymousKey)
        UserDefaults.standard.removeObject(forKey: pendingLinkKey)
        ZeroSettle.shared.setStoreKitEnvironmentForTesting(nil)
        ZeroSettle.baseURLOverride = nil
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
    }
}
