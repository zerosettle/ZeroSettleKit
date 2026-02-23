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

    /// The lifecycle status of an entitlement.
    ///
    /// Unknown server values are preserved via `.unknown(String)` for forward compatibility.
    public enum Status: Sendable, Equatable, Hashable {
        case active
        case paused
        case expired
        case revoked
        case unknown(String)

        /// The raw string value for serialization and wrapper bridge code.
        public var rawString: String {
            switch self {
            case .active: return "active"
            case .paused: return "paused"
            case .expired: return "expired"
            case .revoked: return "revoked"
            case .unknown(let value): return value
            }
        }

        init(rawString: String) {
            switch rawString {
            case "active": self = .active
            case "paused": self = .paused
            case "expired": self = .expired
            case "revoked": self = .revoked
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

    /// When the purchase was made
    public let purchasedAt: Date

    /// Whether this entitlement is currently paused.
    public var isPaused: Bool {
        status == .paused
    }

    private enum CodingKeys: String, CodingKey {
        case id, productId, source, isActive, status
        case pausedAt, pauseResumesAt, expiresAt, purchasedAt
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
        if let rawStatus = try container.decodeIfPresent(String.self, forKey: .status) {
            status = Status(rawString: rawStatus)
        } else {
            // When absent from JSON, default to .active since isActive is the authoritative field
            status = .active
        }
        pausedAt = try container.decodeIfPresent(Date.self, forKey: .pausedAt)
        pauseResumesAt = try container.decodeIfPresent(Date.self, forKey: .pauseResumesAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        purchasedAt = try container.decode(Date.self, forKey: .purchasedAt)
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
        try container.encode(purchasedAt, forKey: .purchasedAt)
    }
}