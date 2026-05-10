import XCTest
@testable import ZeroSettleKit

@MainActor
final class ZSOfferManagerBookkeepingTests: XCTestCase {

    private func makeManager(
        state: Offer.State,
        offerData: Offer.OfferData?
    ) -> ZSOfferManager {
        // Use the internal init to avoid the public init's deprecation warning.
        let mgr = ZSOfferManager(activeUserId: "user_test", stripeCustomerId: nil)
        mgr._setStateForTesting(state)
        mgr._setOfferDataForTesting(offerData)
        return mgr
    }

    /// Build a minimal `Offer.OfferData`. `needsAppleCancel` is a *computed*
    /// property derived from `flowType` / `upgradeType`:
    ///   - `.migration`                    → true
    ///   - `.upgrade` + `.storekitToWeb`   → true
    ///   - `.upgrade` + `.webToWeb`        → false
    /// Pass the desired combination to drive that branch in tests.
    private func makeOfferData(
        flowType: Offer.FlowType = .migration,
        upgradeType: Offer.UpgradeType? = nil
    ) -> Offer.OfferData {
        let display = Offer.Display(
            offerTitle: "",
            offerMessage: "",
            offerCta: "",
            acceptedTitle: "",
            acceptedMessage: "",
            acceptedCta: "",
            completedTitle: "",
            completedMessage: ""
        )
        return Offer.OfferData(
            flowType: flowType,
            productId: "com.example.pro_monthly",
            eligibleProductIds: ["com.example.pro_monthly"],
            savingsPercent: 20,
            display: display,
            freeTrialDays: 0,
            minSubscriptionDays: 0,
            maxSubscriptionDays: nil,
            rolloutPercent: 100,
            upgradeType: upgradeType,
            fromProductId: nil,
            toProductId: nil,
            variantId: nil,
            perProductPrompts: nil,
            checkoutPresentation: nil
        )
    }

    // MARK: _armForCheckout

    func test_armForCheckout_fromEligible_transitionsToPresented() {
        let mgr = makeManager(state: .eligible, offerData: makeOfferData())
        mgr._armForCheckout(source: .auto)
        XCTAssertEqual(mgr.state, .presented)
    }

    func test_armForCheckout_fromPresented_isIdempotent() {
        let mgr = makeManager(state: .presented, offerData: makeOfferData())
        mgr._armForCheckout(source: .auto)
        XCTAssertEqual(mgr.state, .presented)
    }

    func test_armForCheckout_fromAccepted_isNoOp() {
        let mgr = makeManager(state: .accepted, offerData: makeOfferData())
        mgr._armForCheckout(source: .auto)
        XCTAssertEqual(mgr.state, .accepted)
    }

    func test_armForCheckout_fromCompleted_isNoOp() {
        let mgr = makeManager(state: .completed, offerData: makeOfferData())
        mgr._armForCheckout(source: .auto)
        XCTAssertEqual(mgr.state, .completed)
    }

    func test_armForCheckout_fromIneligible_isNoOp() {
        let mgr = makeManager(state: .ineligible, offerData: makeOfferData())
        mgr._armForCheckout(source: .auto)
        XCTAssertEqual(mgr.state, .ineligible)
    }

    func test_armForCheckout_fromDismissed_isNoOp() {
        let mgr = makeManager(state: .dismissed, offerData: makeOfferData())
        mgr._armForCheckout(source: .auto)
        XCTAssertEqual(mgr.state, .dismissed)
    }

    // MARK: _applyCheckoutCompletion

    func test_applyCheckoutCompletion_fromPresented_needsAppleCancel_transitionsToAccepted() async {
        // .migration → needsAppleCancel == true
        let mgr = makeManager(state: .presented, offerData: makeOfferData(flowType: .migration))
        await mgr._applyCheckoutCompletion(transactionId: "txn_123", source: .auto)
        XCTAssertEqual(mgr.state, .accepted)
        XCTAssertTrue(mgr.storekitCancelRequired)
    }

    func test_applyCheckoutCompletion_fromPresented_noAppleCancel_transitionsToCompleted() async {
        // .upgrade + .webToWeb → needsAppleCancel == false
        let mgr = makeManager(
            state: .presented,
            offerData: makeOfferData(flowType: .upgrade, upgradeType: .webToWeb)
        )
        await mgr._applyCheckoutCompletion(transactionId: "txn_123", source: .auto)
        XCTAssertEqual(mgr.state, .completed)
        XCTAssertFalse(mgr.storekitCancelRequired)
    }

    func test_applyCheckoutCompletion_fromEligible_isNoOp() async {
        let mgr = makeManager(state: .eligible, offerData: makeOfferData())
        await mgr._applyCheckoutCompletion(transactionId: "txn_123", source: .auto)
        XCTAssertEqual(mgr.state, .eligible)
    }

    func test_applyCheckoutCompletion_fromAccepted_isIdempotent() async {
        let mgr = makeManager(state: .accepted, offerData: makeOfferData())
        await mgr._applyCheckoutCompletion(transactionId: "txn_456", source: .auto)
        XCTAssertEqual(mgr.state, .accepted)
    }

    func test_applyCheckoutCompletion_setsCheckoutTransactionId() async {
        let mgr = makeManager(
            state: .presented,
            offerData: makeOfferData(flowType: .upgrade, upgradeType: .webToWeb)
        )
        await mgr._applyCheckoutCompletion(transactionId: "txn_specific", source: .auto)
        XCTAssertEqual(mgr.checkoutTransactionId, "txn_specific")
    }

    func test_applyCheckoutCompletion_acceptsNilTransactionId() async {
        let mgr = makeManager(
            state: .presented,
            offerData: makeOfferData(flowType: .upgrade, upgradeType: .webToWeb)
        )
        await mgr._applyCheckoutCompletion(transactionId: nil, source: .auto)
        XCTAssertEqual(mgr.state, .completed)
        XCTAssertNil(mgr.checkoutTransactionId)
    }

    // MARK: Public method regression (post-refactor)
    //
    // These four tests exist BY DESIGN to verify the deprecated public
    // `present()` and `markCheckoutSucceeded(transactionId:)` keep working
    // through the 1.x line. Each is annotated `@available(*, deprecated)`
    // to silence the deprecation warning on the call sites — testing a
    // deprecated API IS a legitimate (and the only honest) use of it.

    @available(*, deprecated)
    func test_legacyPresent_fromEligible_transitionsToPresented() {
        let mgr = makeManager(state: .eligible, offerData: makeOfferData())
        mgr.present()
        XCTAssertEqual(mgr.state, .presented)
    }

    @available(*, deprecated)
    func test_legacyPresent_fromIneligible_isNoOp() {
        let mgr = makeManager(state: .ineligible, offerData: makeOfferData())
        mgr.present()
        XCTAssertEqual(mgr.state, .ineligible)
    }

    @available(*, deprecated)
    func test_legacyMarkCheckoutSucceeded_withNilTxnId_advancesState() async {
        // .upgrade + .webToWeb → needsAppleCancel == false → .completed
        let mgr = makeManager(
            state: .presented,
            offerData: makeOfferData(flowType: .upgrade, upgradeType: .webToWeb)
        )
        await mgr.markCheckoutSucceeded(transactionId: nil)
        XCTAssertEqual(mgr.state, .completed)
    }

    @available(*, deprecated)
    func test_legacyMarkCheckoutSucceeded_alreadyAccepted_isNoOp() async {
        let mgr = makeManager(state: .accepted, offerData: makeOfferData())
        await mgr.markCheckoutSucceeded(transactionId: "txn_x")
        XCTAssertEqual(mgr.state, .accepted)
    }
}
