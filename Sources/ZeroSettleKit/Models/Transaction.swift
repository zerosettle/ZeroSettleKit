//
//  Transaction.swift
//  ZeroSettleKit
//
//  Transaction models for purchase results.
//

import Foundation

// MARK: - StoreKitSubscriptionStatus

/// The lifecycle status of a StoreKit subscription.
/// Maps to Apple's `Product.SubscriptionInfo.RenewalState` raw values.
public enum StoreKitSubscriptionStatus: Int, Sendable, Codable, Hashable {
    case subscribed = 1
    case expired = 2
    case billingRetry = 3
    case gracePeriod = 4
    case revoked = 5
}

// MARK: - CheckoutTransaction

/// Represents a completed or pending purchase transaction.
public struct CheckoutTransaction: Identifiable, Sendable, Equatable {

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

    /// StoreKit subscription status from the backend (1=subscribed, 2=expired, 3=billingRetry, 4=gracePeriod, 5=revoked).
    public let storekitStatus: Int?

    /// Type-safe StoreKit subscription status. `nil` when not a StoreKit subscription or the value is unrecognized.
    public var subscriptionStatus: StoreKitSubscriptionStatus? {
        storekitStatus.flatMap(StoreKitSubscriptionStatus.init(rawValue:))
    }

    public init(
        id: String,
        productId: String,
        status: Status,
        source: Entitlement.Source,
        purchasedAt: Date,
        expiresAt: Date? = nil,
        productName: String? = nil,
        amountCents: Int? = nil,
        currency: String? = nil,
        storekitStatus: Int? = nil
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
        self.storekitStatus = storekitStatus
    }
}

// MARK: - Codable

extension CheckoutTransaction: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, productId, status, source, purchasedAt, expiresAt
        case productName, amountCents, currency, storekitStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        productId = try container.decode(String.self, forKey: .productId)
        // Resilient decoding: unknown status values fall back to .failed
        if let rawStatus = try? container.decode(Status.self, forKey: .status) {
            status = rawStatus
        } else {
            status = .failed
        }
        source = try container.decode(Entitlement.Source.self, forKey: .source)
        purchasedAt = try container.decode(Date.self, forKey: .purchasedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        amountCents = try container.decodeIfPresent(Int.self, forKey: .amountCents)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        storekitStatus = try container.decodeIfPresent(Int.self, forKey: .storekitStatus)
    }
}

// MARK: - Hashable

extension CheckoutTransaction: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}