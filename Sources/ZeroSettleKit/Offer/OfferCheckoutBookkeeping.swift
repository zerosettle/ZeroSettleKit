import Foundation

/// Auto-bookkeeping helpers for offer-bound purchases.
///
/// Called from the three Kit choke points that initiate web checkout:
///   1. `CheckoutSheet.present(...)` — UIKit imperative
///   2. `CheckoutSheetModifier` (and item variants) — SwiftUI modifier path
///   3. `ZeroSettle.shared.purchase(...)` — unified facade web path
///
/// Both functions consult `ZeroSettle.shared._activeOfferManagerForBookkeeping`
/// (non-instantiating) and apply the offer state machine ONLY when:
///   - A manager exists.
///   - It has `offerData` and the data's `checkoutProductId` matches the
///     productId being purchased.
///   - State is `.eligible` or `.presented` (excludes dismissed/ineligible/
///     loading/accepted/completed).
///
/// Both are idempotent by state guard (delegated to `ZSOfferManager._armForCheckout`
/// and `ZSOfferManager._applyCheckoutCompletion`), so combined manual + auto
/// paths cannot double-fire. Calls with no offer context are zero-overhead nil
/// checks.

/// Advance the active offer manager into `.presented` if a checkout is starting
/// for an offer-bound product. No-op otherwise.
@MainActor
internal func armOfferForCheckoutIfApplicable(productId: String) {
    guard let mgr = activeOfferContext(productId: productId) else { return }
    mgr._armForCheckout(source: .auto)
}

/// Apply checkout completion bookkeeping (state → `.accepted` or `.completed`)
/// for the active offer manager when the purchase belongs to an offer-bound
/// product. No-op otherwise.
@MainActor
internal func applyOfferCheckoutCompletionIfApplicable(
    productId: String,
    transactionId: String?
) async {
    guard let mgr = activeOfferContext(productId: productId) else { return }
    await mgr._applyCheckoutCompletion(transactionId: transactionId, source: .auto)
}

/// The active-offer detection rule. Returns the singleton offer manager only
/// when the purchase is offer-bound for the supplied `productId`.
@MainActor
private func activeOfferContext(productId: String) -> ZSOfferManager? {
    guard let mgr = ZeroSettle.shared._activeOfferManagerForBookkeeping else { return nil }
    guard let data = mgr.offerData else { return nil }
    guard mgr.state == .eligible || mgr.state == .presented else { return nil }
    guard data.checkoutProductId == productId else { return nil }
    return mgr
}
