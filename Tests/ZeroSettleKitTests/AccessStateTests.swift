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

    private func clearCache(for users: [String]) {
        for user in users {
            for sandbox in [true, false] {
                UserDefaults.standard.removeObject(forKey: AccessStore.key(userId: user, sandbox: sandbox))
            }
        }
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
        let keyA = AccessStore.key(userId: "user-a", sandbox: zs.isSandbox)
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
        let live = AccessStore.key(userId: "user-a", sandbox: false)
        let sandbox = AccessStore.key(userId: "user-a", sandbox: true)
        XCTAssertTrue(live.hasPrefix("zs.access.v1.live."))
        XCTAssertTrue(sandbox.hasPrefix("zs.access.v1.sandbox."))
        XCTAssertEqual(live.split(separator: ".").last?.count, 16)
        XCTAssertNotEqual(live, AccessStore.key(userId: "user-b", sandbox: false))
        XCTAssertFalse(live.contains("user-a"))
    }

    func test_foreground_refresh_throttled() {
        let now = Date()
        // No identified user: never refresh.
        XCTAssertFalse(zs.handleDidBecomeActive(now: now))

        zs.switchAccessUser(to: "user-a")
        // Identified and never refreshed: refresh.
        XCTAssertTrue(zs.handleDidBecomeActive(now: now))

        zs.recordAccessRefresh(at: now)
        XCTAssertFalse(zs.handleDidBecomeActive(now: now.addingTimeInterval(59)))
        XCTAssertTrue(zs.handleDidBecomeActive(now: now.addingTimeInterval(61)))
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
