import XCTest
@testable import ZeroSettleKit

@MainActor
final class OfferCheckoutBookkeepingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset the cached offerManager singleton so each test starts clean.
        ZeroSettle.shared._resetForTesting()
    }

    /// Build a minimal `Offer.OfferData`. `needsAppleCancel` is computed from
    /// `flowType` / `upgradeType`:
    ///   - `.migration`                    → true
    ///   - `.upgrade` + `.storekitToWeb`   → true
    ///   - `.upgrade` + `.webToWeb`        → false
    private func makeOfferData(
        productId: String,
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
            productId: productId,
            eligibleProductIds: [productId],
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

    /// Prime the shared singleton offer manager into a known state with
    /// offerData attached, so the helper's active-offer detection rule fires.
    @discardableResult
    private func primeManager(
        state: Offer.State,
        productId: String,
        needsAppleCancel: Bool = true
    ) -> ZSOfferManager {
        let mgr = ZeroSettle.shared.offerManager()
        let data: Offer.OfferData
        if needsAppleCancel {
            data = makeOfferData(productId: productId, flowType: .migration)
        } else {
            data = makeOfferData(
                productId: productId,
                flowType: .upgrade,
                upgradeType: .webToWeb
            )
        }
        mgr._setOfferDataForTesting(data)
        mgr._setStateForTesting(state)
        return mgr
    }

    // MARK: arm

    func test_arm_noManager_isNoOp() {
        // No offerManager() call yet — helper must not instantiate one.
        armOfferForCheckoutIfApplicable(productId: "any.product")
        XCTAssertNil(ZeroSettle.shared._activeOfferManagerForBookkeeping)
    }

    func test_arm_managerEligible_matchingProduct_advancesState() {
        let mgr = primeManager(state: .eligible, productId: "com.example.pro")
        armOfferForCheckoutIfApplicable(productId: "com.example.pro")
        XCTAssertEqual(mgr.state, .presented)
    }

    func test_arm_managerEligible_differentProduct_doesNotAdvance() {
        let mgr = primeManager(state: .eligible, productId: "com.example.pro")
        armOfferForCheckoutIfApplicable(productId: "com.example.other")
        XCTAssertEqual(mgr.state, .eligible)
    }

    func test_arm_managerDismissed_doesNotAdvance() {
        let mgr = primeManager(state: .dismissed, productId: "com.example.pro")
        armOfferForCheckoutIfApplicable(productId: "com.example.pro")
        XCTAssertEqual(mgr.state, .dismissed)
    }

    func test_arm_managerIneligible_doesNotAdvance() {
        let mgr = primeManager(state: .ineligible, productId: "com.example.pro")
        armOfferForCheckoutIfApplicable(productId: "com.example.pro")
        XCTAssertEqual(mgr.state, .ineligible)
    }

    func test_arm_managerLoading_doesNotAdvance() {
        let mgr = primeManager(state: .loading, productId: "com.example.pro")
        armOfferForCheckoutIfApplicable(productId: "com.example.pro")
        XCTAssertEqual(mgr.state, .loading)
    }

    // MARK: apply

    func test_apply_managerPresented_matchingProduct_needsAppleCancel_advancesToAccepted() async {
        let mgr = primeManager(
            state: .presented,
            productId: "com.example.pro",
            needsAppleCancel: true
        )
        await applyOfferCheckoutCompletionIfApplicable(
            productId: "com.example.pro",
            transactionId: "txn_1"
        )
        XCTAssertEqual(mgr.state, .accepted)
    }

    func test_apply_managerPresented_matchingProduct_noAppleCancel_advancesToCompleted() async {
        let mgr = primeManager(
            state: .presented,
            productId: "com.example.pro",
            needsAppleCancel: false
        )
        await applyOfferCheckoutCompletionIfApplicable(
            productId: "com.example.pro",
            transactionId: "txn_1"
        )
        XCTAssertEqual(mgr.state, .completed)
    }

    func test_apply_managerPresented_differentProduct_isNoOp() async {
        let mgr = primeManager(state: .presented, productId: "com.example.pro")
        await applyOfferCheckoutCompletionIfApplicable(
            productId: "com.example.other",
            transactionId: "txn_1"
        )
        XCTAssertEqual(mgr.state, .presented)
    }

    func test_apply_noManager_isNoOp() async {
        await applyOfferCheckoutCompletionIfApplicable(
            productId: "any",
            transactionId: "txn_1"
        )
        XCTAssertNil(ZeroSettle.shared._activeOfferManagerForBookkeeping)
    }
}
