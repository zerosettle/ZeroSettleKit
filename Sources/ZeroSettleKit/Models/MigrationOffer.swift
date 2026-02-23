//
//  MigrationOffer.swift
//  ZeroSettleKit
//
//  Migration offer state machine types.
//  Uses uninhabited enum as namespace (matches CancelFlow pattern).
//

import Foundation

/// Namespace for migration offer types.
///
/// The migration flow encourages StoreKit subscribers to switch to web checkout
/// billing at a discount. Developers can use ``ZSMigrationManager`` with these
/// types to build fully custom migration UIs, or use the built-in ``MigrationTipView``.
///
/// Access types via the namespace: `MigrationOffer.State`, `MigrationOffer.OfferData`, etc.
public enum MigrationOffer {

    /// The current state of the migration offer flow.
    public enum State: Sendable, Equatable {
        /// Waiting for bootstrap to complete before evaluating eligibility.
        case loading
        /// User is not eligible (no StoreKit subscription, already has web entitlement, or backend says no).
        case ineligible
        /// User qualifies for migration; offer data is available.
        case eligible
        /// Offer has been presented to the user / checkout is in progress.
        case presented
        /// Web checkout succeeded; Apple subscription is still active.
        case accepted
        /// Web checkout succeeded AND Apple subscription management was shown.
        case completed
        /// User dismissed the offer (persisted in UserDefaults).
        case dismissed
    }

    /// Data describing the migration offer available to an eligible user.
    public struct OfferData: Sendable, Equatable {
        /// The migration prompt containing title, message, discount, and product ID.
        public let prompt: MigrationPrompt
        /// Days remaining on the user's current StoreKit subscription (used as free trial on web).
        public let freeTrialDays: Int
        /// The product ID of the user's active StoreKit subscription.
        public let activeStoreKitProductId: String
    }
}
