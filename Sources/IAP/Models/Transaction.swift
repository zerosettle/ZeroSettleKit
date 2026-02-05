//
//  Transaction.swift
//  ZeroSettleIAP
//
//  Transaction models for purchase results.
//

import Foundation

// MARK: - ZSTransaction

/// Represents a completed or pending purchase transaction.
public struct ZSTransaction: Identifiable, Sendable, Codable, Equatable {
    /// ZeroSettle transaction ID
    public let id: String

    /// The product that was purchased
    public let productId: String

    /// Current status of the transaction
    public let status: TransactionStatus

    /// Where the purchase originated
    public let source: EntitlementSource

    /// When the purchase was made
    public let purchasedAt: Date

    /// When this entitlement expires (nil for non-expiring products like non-consumables)
    public let expiresAt: Date?

    public init(
        id: String,
        productId: String,
        status: TransactionStatus,
        source: EntitlementSource,
        purchasedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.productId = productId
        self.status = status
        self.source = source
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
    }
}

// MARK: - Transaction Status

/// The status of a transaction.
public enum TransactionStatus: String, Sendable, Codable {
    case completed = "completed"
    case pending = "pending"
    case failed = "failed"
    case refunded = "refunded"
}
