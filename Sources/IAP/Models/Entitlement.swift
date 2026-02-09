//
//  Entitlement.swift
//  ZeroSettleIAP
//
//  Entitlement models representing active purchases.
//

import Foundation

// MARK: - Entitlement

/// Represents an active entitlement from either a StoreKit or web checkout purchase.
/// Used when the developer is not using RevenueCat for entitlement management.
public struct Entitlement: Identifiable, Sendable, Codable, Equatable {
    /// Entitlement identifier
    public let id: String

    /// The product ID associated with this entitlement
    public let productId: String

    /// Where the purchase originated
    public let source: EntitlementSource

    /// Whether this entitlement is currently active
    public let isActive: Bool

    /// When the entitlement expires. `nil` for lifetime/consumable purchases.
    public let expiresAt: Date?

    /// When the purchase was made
    public let purchasedAt: Date

    public init(
        id: String,
        productId: String,
        source: EntitlementSource,
        isActive: Bool,
        expiresAt: Date? = nil,
        purchasedAt: Date
    ) {
        self.id = id
        self.productId = productId
        self.source = source
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.purchasedAt = purchasedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        productId = try container.decode(String.self, forKey: .productId)
        source = try container.decodeIfPresent(EntitlementSource.self, forKey: .source) ?? .webCheckout
        isActive = try container.decode(Bool.self, forKey: .isActive)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        purchasedAt = try container.decode(Date.self, forKey: .purchasedAt)
    }
}

// MARK: - Entitlement Source

/// The origin of a purchase/entitlement.
public enum EntitlementSource: String, Sendable, Codable {
    case storeKit = "store_kit"
    case webCheckout = "web_checkout"
}
