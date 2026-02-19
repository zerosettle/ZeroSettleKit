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
    public enum Source: String, Sendable, Codable {
        case storeKit = "store_kit"
        case webCheckout = "web_checkout"
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

    /// Entitlement status string (e.g., "active", "paused", "expired", "revoked").
    public let status: String?

    /// When the entitlement was paused. `nil` if not paused.
    public let pausedAt: Date?

    /// When a paused entitlement will automatically resume. `nil` if not paused.
    public let pauseResumesAt: Date?

    /// When the entitlement expires. `nil` for lifetime/consumable purchases.
    public let expiresAt: Date?

    /// When the purchase was made
    public let purchasedAt: Date

    /// Whether this entitlement is currently paused.
    public var isPaused: Bool {
        status == "paused"
    }

    public init(
        id: String,
        productId: String,
        source: Source,
        isActive: Bool,
        status: String? = nil,
        pausedAt: Date? = nil,
        pauseResumesAt: Date? = nil,
        expiresAt: Date? = nil,
        purchasedAt: Date
    ) {
        self.id = id
        self.productId = productId
        self.source = source
        self.isActive = isActive
        self.status = status
        self.pausedAt = pausedAt
        self.pauseResumesAt = pauseResumesAt
        self.expiresAt = expiresAt
        self.purchasedAt = purchasedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        productId = try container.decode(String.self, forKey: .productId)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .webCheckout
        isActive = try container.decode(Bool.self, forKey: .isActive)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        pausedAt = try container.decodeIfPresent(Date.self, forKey: .pausedAt)
        pauseResumesAt = try container.decodeIfPresent(Date.self, forKey: .pauseResumesAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        purchasedAt = try container.decode(Date.self, forKey: .purchasedAt)
    }
}