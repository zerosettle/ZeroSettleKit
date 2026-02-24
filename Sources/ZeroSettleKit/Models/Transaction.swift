//
//  Transaction.swift
//  ZeroSettleKit
//
//  Transaction models for purchase results.
//

import Foundation

// MARK: - CheckoutTransaction

/// Represents a completed or pending purchase transaction.
public struct CheckoutTransaction: Identifiable, Sendable, Codable, Equatable {

    // MARK: - Nested Types

    /// The status of a transaction.
    public enum Status: String, Sendable, Codable {
        case completed = "completed"
        case pending = "pending"
        case processing = "processing"
        case failed = "failed"
        case refunded = "refunded"
    }

    // MARK: - Properties

    /// ZeroSettle transaction ID
    public let id: String

    /// The product that was purchased
    public let productId: String

    /// Current status of the transaction
    public let status: Status

    /// Where the purchase originated
    public let source: Entitlement.Source

    /// When the purchase was made
    public let purchasedAt: Date

    /// When this entitlement expires (nil for non-expiring products like non-consumables)
    public let expiresAt: Date?

    /// Human-readable product name (populated in transaction history responses).
    public let productName: String?

    /// Amount charged in cents (populated in transaction history responses).
    public let amountCents: Int?

    /// Currency code, e.g. "usd" (populated in transaction history responses).
    public let currency: String?

    public init(
        id: String,
        productId: String,
        status: Status,
        source: Entitlement.Source,
        purchasedAt: Date,
        expiresAt: Date? = nil,
        productName: String? = nil,
        amountCents: Int? = nil,
        currency: String? = nil
    ) {
        self.id = id
        self.productId = productId
        self.status = status
        self.source = source
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
        self.productName = productName
        self.amountCents = amountCents
        self.currency = currency
    }
}