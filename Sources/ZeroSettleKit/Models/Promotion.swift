//
//  Promotion.swift
//  ZeroSettleKit
//
//  Promotional pricing models.
//

import Foundation

// MARK: - Promotion

/// An active promotion for a product, configured on the ZeroSettle dashboard.
public struct Promotion: Sendable, Codable, Equatable {

    // MARK: - Nested Types

    /// The type of promotional discount.
    public enum Kind: String, Sendable, Codable {
        case percentOff = "percent_off"
        case fixedAmount = "fixed_amount"
        case freeTrial = "free_trial"
    }

    // MARK: - Properties

    /// Unique promotion identifier
    public let id: String

    /// Display name for the promotion (e.g., "Launch Sale")
    public let displayName: String

    /// The promotional price (replaces the standard web price during the promotion)
    public let promotionalPrice: Price

    /// When the promotion expires. `nil` means no expiration.
    public let expiresAt: Date?

    /// The type of promotion
    public let type: Kind

    public init(
        id: String,
        displayName: String,
        promotionalPrice: Price,
        expiresAt: Date? = nil,
        type: Kind
    ) {
        self.id = id
        self.displayName = displayName
        self.promotionalPrice = promotionalPrice
        self.expiresAt = expiresAt
        self.type = type
    }
}