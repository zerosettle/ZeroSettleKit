//
//  IdentityEnumTests.swift
//  ZeroSettleKitTests
//
//  Covers PR C v1 — the Identity enum surface introduced in 1.2.4. These
//  tests focus on the parts that don't require network: anonymous-session
//  UUID persistence and the deferred-identification flag. Full bootstrap
//  paths (`.user`, `.anonymous` round-trip) need a configured backend
//  and are exercised by integration tests / example apps.
//

import XCTest
@testable import ZeroSettleKit

@MainActor
final class IdentityEnumTests: XCTestCase {

    private let key = "zerosettle.anonymous_session_uuid"

    override func setUp() {
        super.setUp()
        // ZeroSettle.shared is a process-wide singleton; clear state from
        // any previous test that may have set currentUserId or persisted
        // an anonymous UUID.
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - Anonymous session UUID

    func testAnonymousSessionGeneratesAndPersistsUUID() async {
        XCTAssertNil(UserDefaults.standard.string(forKey: key),
                     "Precondition: no persisted anonymous UUID")

        // Calling identify(.anonymous) without configure() will throw on
        // the network bootstrap — that's expected; we only care that the
        // UUID got persisted before the network call.
        do {
            _ = try await ZeroSettle.shared.identify(.anonymous)
        } catch {
            // expected without configure() / network
        }

        let persisted = UserDefaults.standard.string(forKey: key)
        XCTAssertNotNil(persisted, "identify(.anonymous) must persist a UUID to UserDefaults")
        XCTAssertNotNil(UUID(uuidString: persisted ?? ""),
                        "Persisted anonymous session id must be a valid UUID string")
    }

    func testAnonymousSessionReusesPersistedUUIDAcrossCalls() async {
        // First call generates
        do { _ = try await ZeroSettle.shared.identify(.anonymous) } catch { }
        let first = UserDefaults.standard.string(forKey: key)

        // Second call must reuse
        do { _ = try await ZeroSettle.shared.identify(.anonymous) } catch { }
        let second = UserDefaults.standard.string(forKey: key)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second,
                       "Anonymous session UUID must be stable across identify(.anonymous) calls")
    }

    func testLogoutClearsAnonymousSessionUUID() async {
        do { _ = try await ZeroSettle.shared.identify(.anonymous) } catch { }
        XCTAssertNotNil(UserDefaults.standard.string(forKey: key))

        ZeroSettle.shared.logout()

        XCTAssertNil(UserDefaults.standard.string(forKey: key),
                     "logout() must clear the persisted anonymous session UUID")
    }

    func testLogoutThenAnonymousGeneratesFreshUUID() async {
        do { _ = try await ZeroSettle.shared.identify(.anonymous) } catch { }
        let before = UserDefaults.standard.string(forKey: key)

        ZeroSettle.shared.logout()
        do { _ = try await ZeroSettle.shared.identify(.anonymous) } catch { }
        let after = UserDefaults.standard.string(forKey: key)

        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after,
                          "Anonymous UUID after logout() must be a fresh value, not the previous session's")
    }

    // MARK: - Deferred identification

    func testDeferredIdentityIsNoop() async throws {
        let result = try await ZeroSettle.shared.identify(.deferred)
        XCTAssertNil(result, "identify(.deferred) must return nil — no catalog fetched")
        XCTAssertNil(ZeroSettle.shared.currentUserId,
                     "identify(.deferred) must not set currentUserId")
        XCTAssertNil(UserDefaults.standard.string(forKey: key),
                     "identify(.deferred) must not generate an anonymous UUID")
    }

    func testDeferredFollowedByAnonymousRunsAnonymousFlow() async {
        _ = try? await ZeroSettle.shared.identify(.deferred)
        XCTAssertNil(UserDefaults.standard.string(forKey: key))

        do { _ = try await ZeroSettle.shared.identify(.anonymous) } catch { }
        XCTAssertNotNil(UserDefaults.standard.string(forKey: key),
                        ".deferred → .anonymous must transition into the anonymous flow")
    }
}
