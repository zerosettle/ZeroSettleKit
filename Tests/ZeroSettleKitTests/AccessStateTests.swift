//
//  AccessStateTests.swift
//  ZeroSettleKitTests
//
//  Public reads, updates, delegate, on-device cache and foreground throttle for
//  plan, add-ons, features and balances.
//

import XCTest
@testable import ZeroSettleKit

@MainActor
final class AccessStateTests: XCTestCase {

    private var zs: ZeroSettle { ZeroSettle.shared }

    private final class Recorder: ZeroSettleDelegate {
        var updates: [ZSAccess] = []
        func zeroSettleAccessDidUpdate(_ access: ZSAccess) { updates.append(access) }
    }

    private func makeAccess(
        features: [String: ZSFeatureValue] = [:],
        plan: ZSPlan? = ZSPlan(key: "pro", name: "Pro", kind: .tier),
        balances: [String: ZSBalance] = [:]
    ) -> ZSAccess {
        ZSAccess(plan: plan, addOns: [], features: features, balances: balances)
    }

    private func makeBalance(remaining: Int) -> ZSBalance {
        ZSBalance(
            currency: ZSCurrency(key: "credits", name: "Credit", plural: "Credits", glyph: "sparkles", offline: "allow"),
            remaining: remaining, limit: 500, resetsAt: nil,
            allowanceRemaining: remaining, rolledOver: 0, purchased: 0
        )
    }

    private var savedConfig: ZeroSettle.Configuration?

    override func setUp() async throws {
        savedConfig = zs.currentConfig
        zs.resetAccessForTesting()
        clearCache(for: ["user-a", "user-b"])
    }

    override func tearDown() async throws {
        zs.delegate = nil
        zs.resetAccessForTesting()
        zs.setConfigForTesting(savedConfig)
        clearCache(for: ["user-a", "user-b"])
    }

    private static let testKeys = ["", "zs_pk_test_access_state", "zs_pk_test_key_one", "zs_pk_test_key_two"]

    private func clearCache(for users: [String]) {
        for user in users {
            for sandbox in [true, false] {
                for key in Self.testKeys {
                    UserDefaults.standard.removeObject(
                        forKey: AccessStore.key(userId: user, sandbox: sandbox, keyHash: AccessStore.keyHash(publishableKey: key))
                    )
                }
                UserDefaults.standard.removeObject(
                    forKey: AccessStore.key(userId: user, sandbox: sandbox, keyHash: zs.accessKeyHash)
                )
            }
        }
    }

    private func useKey(_ key: String) {
        zs.setConfigForTesting(ZeroSettle.Configuration(publishableKey: key))
    }

    func test_has_access_bool_and_text() {
        zs.updateAccess(makeAccess(features: ["on": .bool(true), "off": .bool(false), "q": .text("4K"), "blank": .text("")]))
        XCTAssertTrue(zs.hasAccess("on"))
        XCTAssertFalse(zs.hasAccess("off"))
        XCTAssertTrue(zs.hasAccess("q"))
        XCTAssertFalse(zs.hasAccess("blank"))
        XCTAssertFalse(zs.hasAccess("missing"))
        XCTAssertEqual(zs.plan?.key, "pro")
        XCTAssertEqual(zs.features.count, 4)
    }

    func test_value_returns_text_only() {
        zs.updateAccess(makeAccess(features: ["on": .bool(true), "q": .text("4K")]))
        XCTAssertEqual(zs.value("q"), "4K")
        XCTAssertNil(zs.value("on"))
        XCTAssertNil(zs.value("missing"))
    }

    func test_balance_lookup() {
        zs.updateAccess(makeAccess(balances: ["credits": makeBalance(remaining: 7)]))
        XCTAssertEqual(zs.balance("credits")?.remaining, 7)
        XCTAssertEqual(zs.balances.keys.sorted(), ["credits"])
        XCTAssertNil(zs.balance("nope"))
    }

    func test_offline_defaults_before_first_fetch() {
        zs.setOfflineFeatureDefaultsForTesting(["custom_styles": .bool(true), "export_quality": .text("HD")])
        XCTAssertTrue(zs.hasAccess("custom_styles"))
        XCTAssertEqual(zs.value("export_quality"), "HD")
        XCTAssertFalse(zs.hasAccess("unlisted"))

        // Once an access value has loaded, the default no longer applies, even
        // when that value is an empty feature set.
        zs.updateAccess(makeAccess(features: [:]))
        XCTAssertFalse(zs.hasAccess("custom_styles"))
        XCTAssertNil(zs.value("export_quality"))
    }

    func test_missing_access_keys_keep_cached_value() {
        let recorder = Recorder()
        zs.delegate = recorder
        zs.updateAccess(makeAccess(features: ["a": .bool(true)]))
        zs.updateAccess(.empty)
        XCTAssertTrue(zs.hasAccess("a"))
        XCTAssertEqual(zs.plan?.key, "pro")
        XCTAssertEqual(recorder.updates.count, 1)
    }

    func test_access_updates_broadcast_with_replay() async {
        zs.updateAccess(makeAccess(features: ["a": .bool(true)]))
        let first = zs.accessUpdates
        let second = zs.accessUpdates
        var iteratorOne = first.makeAsyncIterator()
        var iteratorTwo = second.makeAsyncIterator()

        let replayOne = await iteratorOne.next()
        let replayTwo = await iteratorTwo.next()
        XCTAssertEqual(replayOne?.features["a"], .bool(true))
        XCTAssertEqual(replayTwo?.features["a"], .bool(true))

        zs.updateAccess(makeAccess(features: ["a": .bool(false)]))
        let nextOne = await iteratorOne.next()
        let nextTwo = await iteratorTwo.next()
        XCTAssertEqual(nextOne?.features["a"], .bool(false))
        XCTAssertEqual(nextTwo?.features["a"], .bool(false))
        XCTAssertEqual(zs.accessListenerCountForTesting, 2)
    }

    func test_stream_listener_removed_on_termination() async {
        let task = Task { @MainActor in
            for await _ in ZeroSettle.shared.accessUpdates {}
        }
        await Task.yield()
        XCTAssertEqual(zs.accessListenerCountForTesting, 1)
        task.cancel()
        _ = await task.value
        for _ in 0..<50 where zs.accessListenerCountForTesting != 0 { await Task.yield() }
        XCTAssertEqual(zs.accessListenerCountForTesting, 0)
    }

    func test_delegate_called_once_per_change() {
        let recorder = Recorder()
        zs.delegate = recorder
        let value = makeAccess(features: ["a": .bool(true)])
        zs.updateAccess(value)
        zs.updateAccess(value)
        XCTAssertEqual(recorder.updates.count, 1)
        zs.updateAccess(makeAccess(features: ["a": .bool(false)]))
        XCTAssertEqual(recorder.updates.count, 2)
    }

    func test_cache_is_per_user_and_cleared_on_logout() {
        zs.switchAccessUser(to: "user-a")
        zs.updateAccess(makeAccess(features: ["a_only": .bool(true)]))
        let keyA = AccessStore.key(userId: "user-a", sandbox: zs.isSandbox, keyHash: zs.accessKeyHash)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: keyA))

        // Another user never sees the first user's features.
        zs.switchAccessUser(to: "user-b")
        XCTAssertFalse(zs.hasAccess("a_only"))
        XCTAssertNil(zs.plan)

        // The first user's entry is still there and loads before any fetch.
        zs.switchAccessUser(to: "user-a")
        XCTAssertTrue(zs.hasAccess("a_only"))
        XCTAssertEqual(zs.plan?.key, "pro")

        zs.clearAccessForLogout()
        XCTAssertNil(UserDefaults.standard.data(forKey: keyA))
        XCTAssertEqual(zs.access, .empty)
        XCTAssertFalse(zs.hasAccess("a_only"))
    }

    func test_cache_key_shape() {
        let hash = AccessStore.keyHash(publishableKey: "zs_pk_live_one")
        XCTAssertEqual(hash.count, 8)
        let live = AccessStore.key(userId: "user-a", sandbox: false, keyHash: hash)
        let sandbox = AccessStore.key(userId: "user-a", sandbox: true, keyHash: hash)
        XCTAssertTrue(live.hasPrefix("zs.access.v1.live.\(hash)."))
        XCTAssertTrue(sandbox.hasPrefix("zs.access.v1.sandbox.\(hash)."))
        XCTAssertEqual(live.split(separator: ".").last?.count, 16)
        XCTAssertNotEqual(live, AccessStore.key(userId: "user-b", sandbox: false, keyHash: hash))
        XCTAssertNotEqual(live, AccessStore.key(userId: "user-a", sandbox: false, keyHash: AccessStore.keyHash(publishableKey: "zs_pk_live_two")))
        XCTAssertFalse(live.contains("user-a"))
    }

    func test_foreground_refresh_throttled() async {
        let now = Date()
        // Not opted in: never refresh.
        zs.switchAccessUser(to: "user-a")
        XCTAssertFalse(zs.handleDidBecomeActive(now: now))
        zs.switchAccessUser(to: "user-b")
        _ = zs.plan
        zs.clearAccessForLogout()
        // No identified user: never refresh.
        XCTAssertFalse(zs.handleDidBecomeActive(now: now))

        zs.switchAccessUser(to: "user-a")
        XCTAssertTrue(zs.handleDidBecomeActive(now: now))
        // A second activation during the fetch does nothing.
        XCTAssertFalse(zs.handleDidBecomeActive(now: now.addingTimeInterval(100)))
        await zs.foregroundRefreshTask?.value

        XCTAssertFalse(zs.handleDidBecomeActive(now: now.addingTimeInterval(59)))
        XCTAssertTrue(zs.handleDidBecomeActive(now: now.addingTimeInterval(61)))
        await zs.foregroundRefreshTask?.value
    }

    func test_foreground_refresh_once_per_window_even_on_failure() async {
        // No backend is configured, so every refresh ends without a successful read.
        let now = Date()
        _ = zs.plan
        zs.switchAccessUser(to: "user-a")
        XCTAssertTrue(zs.handleDidBecomeActive(now: now))
        await zs.foregroundRefreshTask?.value
        XCTAssertNil(zs.foregroundRefreshTask)
        for offset in [1.0, 20, 59] {
            XCTAssertFalse(zs.handleDidBecomeActive(now: now.addingTimeInterval(offset)), "offset \(offset)")
        }
        XCTAssertTrue(zs.handleDidBecomeActive(now: now.addingTimeInterval(60)))
        await zs.foregroundRefreshTask?.value
    }

    func test_no_foreground_fetch_during_bootstrap() async {
        _ = zs.plan
        zs.switchAccessUser(to: "user-a")
        zs.setBootstrapInFlightForTesting(true)
        XCTAssertFalse(zs.handleDidBecomeActive(now: Date()))
        zs.setBootstrapInFlightForTesting(false)
        XCTAssertTrue(zs.handleDidBecomeActive(now: Date()))
        await zs.foregroundRefreshTask?.value
    }

    // MARK: - Race guards, through the HTTP seam

    private func installHoldingBackend() -> Backend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HoldingURLProtocol.self]
        HoldingURLProtocol.reset()
        let backend = Backend(baseURL: URL(string: "https://example.test")!, publishableKey: "zs_pk_test_x", session: URLSession(configuration: config))
        zs.setBackendForTesting(backend)
        return backend
    }

    private func body(feature: String) -> Data {
        Data(#"{"entitlements": [], "plan": {"key": "pro", "name": "Pro", "kind": "tier"}, "features": {"\#(feature)": true}}"#.utf8)
    }

    private func waitUntilHeld(_ user: String) async {
        for _ in 0..<500 where !HoldingURLProtocol.isHolding(user) { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(HoldingURLProtocol.isHolding(user))
    }

    func test_stale_response_for_previous_user_is_dropped() async throws {
        let savedBackend = zs.backendForTesting
        defer { zs.setBackendForTesting(savedBackend) }
        _ = installHoldingBackend()
        HoldingURLProtocol.hold(user: "user-a", body: body(feature: "a_only"))

        zs.switchAccessUser(to: "user-a")
        let stale = Task { @MainActor in _ = try? await ZeroSettle.shared._restoreEntitlementsImpl(userId: "user-a") }
        await waitUntilHeld("user-a")

        zs.switchAccessUser(to: "user-b")
        let bAccess = makeAccess(features: ["b_only": .bool(true)])
        zs.updateAccess(bAccess)

        HoldingURLProtocol.release(user: "user-a")
        await stale.value

        XCTAssertEqual(zs.access, bAccess)
        XCTAssertFalse(zs.hasAccess("a_only"))
        XCTAssertEqual(AccessStore.load(userId: "user-b", sandbox: zs.isSandbox, keyHash: zs.accessKeyHash), bAccess)
        XCTAssertNil(AccessStore.load(userId: "user-a", sandbox: zs.isSandbox, keyHash: zs.accessKeyHash))
    }

    func test_logout_cannot_be_undone_by_in_flight_refresh() async throws {
        let savedBackend = zs.backendForTesting
        defer { zs.setBackendForTesting(savedBackend) }
        _ = installHoldingBackend()
        HoldingURLProtocol.hold(user: "user-a", body: body(feature: "a_only"))

        zs.switchAccessUser(to: "user-a")
        let stale = Task { @MainActor in _ = try? await ZeroSettle.shared._restoreEntitlementsImpl(userId: "user-a") }
        await waitUntilHeld("user-a")

        zs.clearAccessForLogout()
        HoldingURLProtocol.release(user: "user-a")
        await stale.value

        XCTAssertEqual(zs.access, .empty)
        XCTAssertFalse(zs.hasAccess("a_only"))
        XCTAssertNil(AccessStore.load(userId: "user-a", sandbox: zs.isSandbox, keyHash: zs.accessKeyHash))
    }

    func test_switch_never_shows_previous_users_features() async {
        zs.switchAccessUser(to: "user-a")
        zs.updateAccess(makeAccess(features: ["a_only": .bool(true)]))
        var iterator = zs.accessUpdates.makeAsyncIterator()
        let replay = await iterator.next()
        XCTAssertTrue(replay?.features["a_only"] != nil)

        zs.switchAccessUser(to: "user-b")
        XCTAssertFalse(zs.hasAccess("a_only"))
        zs.updateAccess(makeAccess(features: ["b_only": .bool(true)]))

        // Every value published after the switch belongs to the new user only.
        let afterSwitch = await iterator.next()
        XCTAssertNil(afterSwitch?.features["a_only"])
        XCTAssertEqual(afterSwitch?.features["b_only"], .bool(true))
    }

    // MARK: - Opt-in foreground refresh, RevenueCat mode, logout fencing

    private func entitlementsBody(feature: String) -> Data {
        Data("""
        {"entitlements": [{"id": "ent_1", "product_id": "com.app.pro", "source": "web_checkout", "is_active": true,
          "status": "active", "expires_at": "2099-06-15T00:00:00Z", "will_renew": true, "is_trial": false,
          "purchased_at": "2024-06-15T00:00:00Z"}],
         "plan": {"key": "pro", "name": "Pro", "kind": "tier"}, "features": {"\(feature)": true}}
        """.utf8)
    }

    func test_no_foreground_refresh_until_new_reads_used() async {
        zs.switchAccessUser(to: "user-a")
        XCTAssertFalse(zs.accessReadsUsed)
        XCTAssertFalse(zs.handleDidBecomeActive(now: Date()))
        XCTAssertNil(zs.foregroundRefreshTask)

        // Each of the new reads flips the flag.
        let touches: [() -> Void] = [
            { _ = self.zs.hasAccess("x") }, { _ = self.zs.value("x") }, { _ = self.zs.balance("x") },
            { _ = self.zs.plan }, { _ = self.zs.addOns }, { _ = self.zs.features },
            { _ = self.zs.balances }, { _ = self.zs.access }, { _ = self.zs.accessUpdates },
        ]
        for touch in touches {
            zs.resetAccessForTesting()
            zs.switchAccessUser(to: "user-a")
            touch()
            XCTAssertTrue(zs.accessReadsUsed)
            XCTAssertTrue(zs.handleDidBecomeActive(now: Date()))
            zs.resetAccessForTesting()
        }
    }

    func test_foreground_refresh_reaches_backend_with_storekit_sync_off() async throws {
        let savedBackend = zs.backendForTesting
        defer { zs.setBackendForTesting(savedBackend) }
        _ = installHoldingBackend()
        HoldingURLProtocol.hold(user: "user-a", body: entitlementsBody(feature: "custom_styles"))

        zs.switchAccessUser(to: "user-a")
        _ = zs.plan
        XCTAssertTrue(zs.handleDidBecomeActive(now: Date()))
        await waitUntilHeld("user-a")

        HoldingURLProtocol.release(user: "user-a")
        await zs.foregroundRefreshTask?.value
        XCTAssertTrue(zs.hasAccess("custom_styles"))
        XCTAssertEqual(zs.entitlements.count, 1)
        zs.logout()
    }

    func test_logout_during_foreground_read_publishes_nothing() async throws {
        let savedBackend = zs.backendForTesting
        defer { zs.setBackendForTesting(savedBackend) }
        _ = installHoldingBackend()
        HoldingURLProtocol.hold(user: "user-a", body: entitlementsBody(feature: "a_only"))

        zs.switchAccessUser(to: "user-a")
        _ = zs.plan
        XCTAssertTrue(zs.handleDidBecomeActive(now: Date()))
        let running = zs.foregroundRefreshTask
        await waitUntilHeld("user-a")

        zs.logout()
        XCTAssertNil(zs.foregroundRefreshTask)
        HoldingURLProtocol.release(user: "user-a")
        await running?.value

        XCTAssertTrue(zs.entitlements.isEmpty)
        XCTAssertEqual(zs.access, .empty)
    }

    func test_logout_during_restore_read_publishes_nothing() async throws {
        let savedBackend = zs.backendForTesting
        defer { zs.setBackendForTesting(savedBackend) }
        _ = installHoldingBackend()
        HoldingURLProtocol.hold(user: "user-a", body: entitlementsBody(feature: "a_only"))

        zs.switchAccessUser(to: "user-a")
        let stale = Task { @MainActor in _ = try? await ZeroSettle.shared._restoreEntitlementsImpl(userId: "user-a") }
        await waitUntilHeld("user-a")

        zs.logout()
        HoldingURLProtocol.release(user: "user-a")
        await stale.value

        XCTAssertTrue(zs.entitlements.isEmpty)
        XCTAssertFalse(zs.hasAccess("a_only"))
    }

    func test_checkout_refresh_reaches_backend_with_storekit_sync_off() async throws {
        let savedBackend = zs.backendForTesting
        defer { zs.setBackendForTesting(savedBackend); zs.setCurrentUserIdForTesting(nil) }
        _ = installHoldingBackend()
        HoldingURLProtocol.hold(user: "user-a", body: entitlementsBody(feature: "custom_styles"))

        zs.switchAccessUser(to: "user-a")
        zs.setCurrentUserIdForTesting("user-a")
        let transaction = CheckoutTransaction(
            id: "txn_1", productId: "com.app.pro", status: .completed, source: .webCheckout, purchasedAt: Date()
        )
        let refresh = Task { @MainActor in await ZeroSettle.shared.refreshEntitlementsAfterCheckout(transaction: transaction) }
        await waitUntilHeld("user-a")
        HoldingURLProtocol.release(user: "user-a")
        await refresh.value

        XCTAssertTrue(zs.hasAccess("custom_styles"))
        zs.logout()
    }

    // MARK: - Tenant and ordering

    func test_configure_with_another_key_never_shows_previous_tenants_access() {
        useKey("zs_pk_test_key_one")
        zs.switchAccessUser(to: "user-a")
        zs.updateAccess(makeAccess(features: ["tenant_one": .bool(true)]))
        XCTAssertTrue(zs.hasAccess("tenant_one"))

        // Another key, then the same user identifies again.
        useKey("zs_pk_test_key_two")
        zs.resetAccessForConfigure()
        XCTAssertEqual(zs.access, .empty)
        zs.switchAccessUser(to: "user-a")
        XCTAssertFalse(zs.hasAccess("tenant_one"))
        XCTAssertNil(zs.plan)

        // The first tenant's entry is untouched and loads again under its own key.
        useKey("zs_pk_test_key_one")
        zs.resetAccessForConfigure()
        zs.switchAccessUser(to: "user-a")
        XCTAssertTrue(zs.hasAccess("tenant_one"))
    }

    func test_read_in_flight_across_configure_is_dropped() async throws {
        let savedBackend = zs.backendForTesting
        defer { zs.setBackendForTesting(savedBackend) }
        useKey("zs_pk_test_key_one")
        _ = installHoldingBackend()
        HoldingURLProtocol.hold(user: "user-a", body: body(feature: "tenant_one"))

        zs.switchAccessUser(to: "user-a")
        let stale = Task { @MainActor in _ = try? await ZeroSettle.shared._restoreEntitlementsImpl(userId: "user-a") }
        await waitUntilHeld("user-a")

        useKey("zs_pk_test_key_two")
        zs.resetAccessForConfigure()
        zs.switchAccessUser(to: "user-a")
        HoldingURLProtocol.release(user: "user-a")
        await stale.value

        XCTAssertEqual(zs.access, .empty)
        XCTAssertFalse(zs.hasAccess("tenant_one"))
        XCTAssertNil(AccessStore.load(userId: "user-a", sandbox: zs.isSandbox, keyHash: AccessStore.keyHash(publishableKey: "zs_pk_test_key_two")))
        XCTAssertNil(AccessStore.load(userId: "user-a", sandbox: zs.isSandbox, keyHash: AccessStore.keyHash(publishableKey: "zs_pk_test_key_one")))
    }

    func test_older_read_never_overwrites_newer_one() {
        zs.switchAccessUser(to: "user-a")
        let older = zs.beginAccessRead(userId: "user-a")
        let newer = zs.beginAccessRead(userId: "user-a")
        zs.applyAccessRead(makeAccess(features: ["v": .text("new")]), stamp: newer)
        zs.applyAccessRead(makeAccess(features: ["v": .text("old")]), stamp: older)
        XCTAssertEqual(zs.value("v"), "new")
    }

    func test_static_forwarders_match_shared() {
        zs.updateAccess(makeAccess(features: ["on": .bool(true), "q": .text("4K")], balances: ["credits": makeBalance(remaining: 3)]))
        XCTAssertEqual(ZeroSettle.hasAccess("on"), zs.hasAccess("on"))
        XCTAssertEqual(ZeroSettle.hasAccess("missing"), zs.hasAccess("missing"))
        XCTAssertEqual(ZeroSettle.value("q"), zs.value("q"))
        XCTAssertEqual(ZeroSettle.balance("credits"), zs.balance("credits"))
        XCTAssertEqual(ZeroSettle.plan, zs.plan)
    }
}

/// Holds the response for chosen users until released, so a test can switch users mid-request.
final class HoldingURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var held: [String: HoldingURLProtocol] = [:]
    private static let lock = NSLock()

    static func reset() { lock.lock(); bodies = [:]; held = [:]; lock.unlock() }
    static func hold(user: String, body: Data) { lock.lock(); bodies[user] = body; lock.unlock() }
    static func isHolding(_ user: String) -> Bool { lock.lock(); defer { lock.unlock() }; return held[user] != nil }
    static func release(user: String) {
        lock.lock()
        let proto = held.removeValue(forKey: user)
        let body = bodies[user]
        lock.unlock()
        proto?.finish(body ?? Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let user = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "user_id" }?.value ?? ""
        Self.lock.lock()
        Self.held[user] = self
        Self.lock.unlock()
    }
    override func stopLoading() {}

    fileprivate func finish(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
