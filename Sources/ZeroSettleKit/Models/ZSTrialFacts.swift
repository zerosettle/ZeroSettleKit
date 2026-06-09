//
//  ZSTrialFacts.swift
//  ZeroSettleKit
//
//  Display facts for a product's trial mode, surfaced so the host app can
//  render paywall copy that matches what web checkout will actually do.
//  The SDK owns no payment mechanics here -- those live server-side and in the
//  web checkout template.
//

import Foundation

/// How a free trial is collected for a product, plus the amounts involved.
///
/// Non-nil on `ZSProduct.trial` only for trial-eligible subscription products
/// when a user id was provided to product fetch. The app maps these facts to
/// its own copy (the SDK ships no copy strings).
public struct ZSTrialFacts: Sendable, Equatable, Codable {

    /// The trial collection mode.
    public enum Mode: String, Sendable, Equatable, Codable {
        /// $0 trial -- card saved, charged at trial end (status quo).
        case free
        /// A small real charge kept up front, then full price at trial end.
        case paid
        /// A nominal authorization hold (a "pending charge" deterrent), released
        /// on convert/cancel; the trial itself stays $0.
        case authHold = "auth_hold"
    }

    /// The resolved trial mode for this user + product.
    public let mode: Mode

    /// Free-trial duration token (e.g. "1_week", "30"). `nil` if not provided.
    public let duration: String?

    /// Amount charged up front in `.paid` mode, in cents. `0` otherwise.
    public let upfrontAmountCents: Int

    /// Authorization hold amount in `.authHold` mode, in cents. `0` otherwise.
    public let holdAmountCents: Int

    /// `true` for `.paid` / `.authHold` (a real charge/hold confirms the card).
    public let validatesCard: Bool

    public init(
        mode: Mode,
        duration: String?,
        upfrontAmountCents: Int,
        holdAmountCents: Int,
        validatesCard: Bool
    ) {
        self.mode = mode
        self.duration = duration
        self.upfrontAmountCents = upfrontAmountCents
        self.holdAmountCents = holdAmountCents
        self.validatesCard = validatesCard
    }
}
