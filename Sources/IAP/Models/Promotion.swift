//
//  Promotion.swift
//  ZeroSettleIAP
//
//  Promotional pricing models.
//

import Foundation

// MARK: - Promotion

/// An active promotion for a product, configured on the ZeroSettle dashboard.
public struct Promotion: Sendable, Codable, Equatable {
    /// Unique promotion identifier
    public let id: String

    /// Display name for the promotion (e.g., "Launch Sale")
    public let displayName: String

    /// The promotional price (replaces the standard web price during the promotion)
    public let promotionalPrice: Price

    /// When the promotion expires. `nil` means no expiration.
    public let expiresAt: Date?

    /// The type of promotion
    public let type: PromotionType

    public init(
        id: String,
        displayName: String,
        promotionalPrice: Price,
        expiresAt: Date? = nil,
        type: PromotionType
    ) {
        self.id = id
        self.displayName = displayName
        self.promotionalPrice = promotionalPrice
        self.expiresAt = expiresAt
        self.type = type
    }
}

// MARK: - Promotion Type

/// The type of promotional discount.
public enum PromotionType: String, Sendable, Codable {
    case percentOff = "percent_off"
    case fixedAmount = "fixed_amount"
    case freeTrial = "free_trial"
}
