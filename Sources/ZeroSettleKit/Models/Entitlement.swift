//
//  Entitlement.swift
//  ZeroSettleKit
//
//  Entitlement models representing active purchases.
//

import Foundation

// MARK: - Entitlement

/// Represents an active entitlement from either a StoreKit or web checkout purchase.
/// Used when the developer is not using RevenueCat for entitlement management.
public struct Entitlement: Identifiable, Sendable, Codable, Equatable {

    // MARK: - Nested Types

    /// The origin of a purchase/entitlement.
    ///
    /// A single user can hold entitlements from multiple sources simultaneously
    /// (e.g., a StoreKit subscription and a web checkout consumable).
    public enum Source: String, Sendable, Codable {
        /// Purchased through Apple's StoreKit (App Store billing).
        case storeKit = "store_kit"
        /// Purchased through ZeroSettle's web checkout (Stripe billing).
        case webCheckout = "web_checkout"
    }

    /// The lifecycle status of an entitlement.
    ///
    /// Unknown server values are preserved via `.unknown(String)` for forward compatibility.
    public enum Status: Sendable, Equatable, Hashable {
        case active
        case paused
        case expired
        case revoked
        case cancelled
        case gracePeriod
        case pastDue
        case unknown(String)

        /// The raw string value for serialization and wrapper bridge code.
        public var rawString: String {
            switch self {
            case .active: return "active"
            case .paused: return "paused"
            case .expired: return "expired"
            case .revoked: return "revoked"
            case .cancelled: return "cancelled"
            case .gracePeriod: return "grace_period"
            case .pastDue: return "past_due"
            case .unknown(let value): return value
            }
        }

        init(rawString: String) {
            switch rawString {
            case "active": self = .active
            case "paused": self = .paused
            case "expired": self = .expired
            case "revoked": self = .revoked
            case "cancelled": self = .cancelled
            case "grace_period": self = .gracePeriod
            case "past_due": self = .pastDue
            default: self = .unknown(rawString)
            }
        }
    }

    // MARK: - Properties

    /// Entitlement identifier
    public let id: String

    /// The product ID associated with this entitlement
    public let productId: String

    /// Where the purchase originated
    public let source: Source

    /// Whether this entitlement is currently active
    public let isActive: Bool

    /// The lifecycle status of this entitlement.
    public let status: Status

    /// When the entitlement was paused. `nil` if not paused.
    public let pausedAt: Date?

    /// When a paused entitlement will automatically resume. `nil` if not paused.
    public let pauseResumesAt: Date?

    /// When the entitlement expires. `nil` for lifetime/consumable purchases.
    public let expiresAt: Date?

    /// Whether the subscription will auto-renew at the end of the current period.
    public let willRenew: Bool

    /// Whether this entitlement is currently in a free trial period.
    public let isTrial: Bool

    /// When the free trial period ends. `nil` if not a trial.
    public let trialEndsAt: Date?

    /// When the user cancelled the subscription. `nil` if not cancelled.
    public let cancelledAt: Date?

    /// When the purchase was made
    public let purchasedAt: Date

    /// The original StoreKit transaction ID that groups all renewals of a subscription.
    /// Only present for StoreKit-sourced entitlements.
    public let storekitOriginalTransactionId: String?

    /// The date of the original subscription purchase (first transaction in the group).
    /// Only present for StoreKit-sourced subscription entitlements.
    public let originalPurchaseDate: Date?

    /// Whether this entitlement is currently paused.
    public var isPaused: Bool {
        status == .paused
    }

    /// Whether the user has cancelled but the entitlement is still active until period end.
    public var isCancelled: Bool {
        cancelledAt != nil && isActive
    }

    /// Days remaining in the trial period. `nil` if not a trial.
    public var trialDaysRemaining: Int? {
        guard isTrial, let trialEndsAt else { return nil }
        let remaining = Calendar.current.dateComponents([.day], from: Date(), to: trialEndsAt).day ?? 0
        return max(0, remaining)
    }

    private enum CodingKeys: String, CodingKey {
        case id, productId, source, isActive, status
        case pausedAt, pauseResumesAt, expiresAt, purchasedAt
        case willRenew, isTrial, trialEndsAt, cancelledAt
        case storekitOriginalTransactionId
        case originalPurchaseDate
    }

    public init(
        id: String,
        productId: String,
        source: Source,
        isActive: Bool,
        status: Status = .active,
        pausedAt: Date? = nil,
        pauseResumesAt: Date? = nil,
        expiresAt: Date? = nil,
        willRenew: Bool = true,
        isTrial: Bool = false,
        trialEndsAt: Date? = nil,
        cancelledAt: Date? = nil,
        purchasedAt: Date,
        storekitOriginalTransactionId: String? = nil,
        originalPurchaseDate: Date? = nil
    ) {
        self.id = id
        self.productId = productId
        self.source = source
        self.isActive = isActive
        self.status = status
        self.pausedAt = pausedAt
        self.pauseResumesAt = pauseResumesAt
        self.expiresAt = expiresAt
        self.willRenew = willRenew
        self.isTrial = isTrial
        self.trialEndsAt = trialEndsAt
        self.cancelledAt = cancelledAt
        self.purchasedAt = purchasedAt
        self.storekitOriginalTransactionId = storekitOriginalTransactionId
        self.originalPurchaseDate = originalPurchaseDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        productId = try container.decode(String.self, forKey: .productId)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .webCheckout
        isActive = try container.decode(Bool.self, forKey: .isActive)
        if let rawStatus = try container.decodeIfPresent(String.self, forKey: .status) {
            status = Status(rawString: rawStatus)
        } else {
            // When absent from JSON, default to .active since isActive is the authoritative field
            status = .active
        }
        pausedAt = try container.decodeIfPresent(Date.self, forKey: .pausedAt)
        pauseResumesAt = try container.decodeIfPresent(Date.self, forKey: .pauseResumesAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        willRenew = try container.decodeIfPresent(Bool.self, forKey: .willRenew) ?? true
        isTrial = try container.decodeIfPresent(Bool.self, forKey: .isTrial) ?? false
        trialEndsAt = try container.decodeIfPresent(Date.self, forKey: .trialEndsAt)
        cancelledAt = try container.decodeIfPresent(Date.self, forKey: .cancelledAt)
        purchasedAt = try container.decode(Date.self, forKey: .purchasedAt)
        storekitOriginalTransactionId = try container.decodeIfPresent(String.self, forKey: .storekitOriginalTransactionId)
        originalPurchaseDate = try container.decodeIfPresent(Date.self, forKey: .originalPurchaseDate)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(productId, forKey: .productId)
        try container.encode(source, forKey: .source)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(status.rawString, forKey: .status)
        try container.encodeIfPresent(pausedAt, forKey: .pausedAt)
        try container.encodeIfPresent(pauseResumesAt, forKey: .pauseResumesAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(willRenew, forKey: .willRenew)
        try container.encode(isTrial, forKey: .isTrial)
        try container.encodeIfPresent(trialEndsAt, forKey: .trialEndsAt)
        try container.encodeIfPresent(cancelledAt, forKey: .cancelledAt)
        try container.encode(purchasedAt, forKey: .purchasedAt)
        try container.encodeIfPresent(storekitOriginalTransactionId, forKey: .storekitOriginalTransactionId)
        try container.encodeIfPresent(originalPurchaseDate, forKey: .originalPurchaseDate)
    }
}

// MARK: - Hashable

extension Entitlement: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}