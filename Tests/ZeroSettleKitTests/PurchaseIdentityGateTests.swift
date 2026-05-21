//
//  PurchaseIdentityGateTests.swift
//  ZeroSettleKitTests
//
//  Regression coverage for the "userId is required for auto_renewable_subscription
//  products" crash: `purchase()` / `purchaseViaStoreKit()` used the legacy
//  `validateUserIdIfRequired` helper, which `assertionFailure`-crashed in DEBUG
//  when no userId reached it. They now resolve identity the same way every
//  other user-scoped API does — via `requireIdentifiedUserId()` — and throw a
//  clean `ZeroSettleError.userNotIdentified` instead.
//
//  Contract pinned here:
//    - A configured-but-unidentified SDK rejects purchases with
//      `userNotIdentified` (no crash, no `userIdRequired`).
//    - `identify(.deferred)` does NOT count as identified — purchases stay
//      blocked until `.user(...)` / `.anonymous` resolves.
//    - `identify(.user)` / `.anonymous` populate `currentUserId`, satisfying
//      the gate.
//

import XCTest
@testable import ZeroSettleKit

@MainActor
final class PurchaseIdentityGateTests: XCTestCase {

    private let anonKey = "zerosettle.anonymous_session_uuid"
    private let productId = "com.test.pro_monthly"

    override func setUp() {
        super.setUp()
        // ZeroSettle.shared is a process-wide singleton — clear identity state
        // leaked from prior tests, then configure so purchase() clears the
        // `notConfigured` guard and reaches the identity gate.
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonKey)
        ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_test_purchaseIdentityGate"))
    }

    override func tearDown() {
        ZeroSettle.shared.logout()
        UserDefaults.standard.removeObject(forKey: anonKey)
        super.tearDown()
    }

    /// Sets `currentUserId` by calling identify() and tolerating the network
    /// failure (no backend in the test runner). `setActiveUserId` runs before
    /// the network call, so `currentUserId` is populated regardless.
    private func identify(_ identity: Identity) async {
        do { _ = try await ZeroSettle.shared.identify(identity) }
        catch { /* expected without a configured backend */ }
    }

    // MARK: - purchase() (web checkout)

    /// THE REGRESSION: configured + never identified → clean `userNotIdentified`,
    /// not the old `assertionFailure` crash / `userIdRequired`.
    func test_purchase_withoutIdentify_throwsUserNotIdentified() async {
        do {
            _ = try await ZeroSettle.shared.purchase(productId: productId)
            XCTFail("purchase() must reject an unidentified caller")
        } catch ZeroSettleError.userNotIdentified {
            // expected
        } catch {
            XCTFail("expected ZeroSettleError.userNotIdentified, got \(error)")
        }
    }

    /// `identify(.deferred)` records intent only — it does not identify a user.
    /// Purchases stay blocked until `.user(...)` / `.anonymous` resolves.
    func test_purchase_afterDeferredIdentify_throwsUserNotIdentified() async {
        await identify(.deferred)
        XCTAssertNil(ZeroSettle.shared.currentUserId,
                     "precondition: .deferred must not populate currentUserId")
        do {
            _ = try await ZeroSettle.shared.purchase(productId: productId)
            XCTFail("purchase() must reject a .deferred (un-identified) caller")
        } catch ZeroSettleError.userNotIdentified {
            // expected
        } catch {
            XCTFail("expected ZeroSettleError.userNotIdentified, got \(error)")
        }
    }

    // MARK: - purchaseViaStoreKit()

    /// The StoreKit path shares the identity gate, checked before the product
    /// lookup so the contract fails fast and consistently.
    func test_purchaseViaStoreKit_withoutIdentify_throwsUserNotIdentified() async {
        do {
            _ = try await ZeroSettle.shared.purchaseViaStoreKit(productId: productId)
            XCTFail("purchaseViaStoreKit() must reject an unidentified caller")
        } catch ZeroSettleError.userNotIdentified {
            // expected
        } catch {
            XCTFail("expected ZeroSettleError.userNotIdentified, got \(error)")
        }
    }

    func test_purchaseViaStoreKit_afterDeferredIdentify_throwsUserNotIdentified() async {
        await identify(.deferred)
        do {
            _ = try await ZeroSettle.shared.purchaseViaStoreKit(productId: productId)
            XCTFail("purchaseViaStoreKit() must reject a .deferred caller")
        } catch ZeroSettleError.userNotIdentified {
            // expected
        } catch {
            XCTFail("expected ZeroSettleError.userNotIdentified, got \(error)")
        }
    }

    // MARK: - Identity enum: .user / .anonymous satisfy the gate

    /// `identify(.user)` and `identify(.anonymous)` both populate `currentUserId`
    /// — the value `requireIdentifiedUserId()` consumes — so purchases are no
    /// longer blocked once either resolves.
    func test_userIdentify_satisfiesPurchaseGate() async {
        await identify(.user(id: "identified-alice"))
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "identified-alice",
                       ".user(id:) must populate currentUserId, satisfying the purchase gate")
    }

    func test_anonymousIdentify_satisfiesPurchaseGate() async {
        await identify(.anonymous)
        XCTAssertNotNil(ZeroSettle.shared.currentUserId,
                        ".anonymous must populate currentUserId, satisfying the purchase gate")
    }

    // MARK: - The reported crash scenario, positive side

    /// The exact case that crashed: an *identified* user calls `purchase()` on
    /// a subscription. It must clear the identity gate — no `assertionFailure`
    /// abort, no `userNotIdentified`. It then proceeds into the checkout flow,
    /// which fails with a backend/network error in the test runner (no live
    /// backend) — that downstream failure is expected and not asserted here.
    func test_purchase_afterUserIdentify_clearsIdentityGate() async {
        await identify(.user(id: "identified-alice"))
        XCTAssertEqual(ZeroSettle.shared.currentUserId, "identified-alice",
                       "precondition: identify(.user) populated currentUserId")
        do {
            _ = try await ZeroSettle.shared.purchase(productId: productId)
        } catch ZeroSettleError.userNotIdentified {
            XCTFail("an identified caller must clear the identity gate, not be rejected")
        } catch {
            // Expected: downstream checkout/network error — the gate was cleared.
        }
    }
}
