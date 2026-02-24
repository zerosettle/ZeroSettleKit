//
//  UpgradeOffer.swift
//  ZeroSettleKit
//
//  Upgrade offer types for subscription tier upgrades.
//  Uses uninhabited enum as namespace: UpgradeOffer.Config, UpgradeOffer.Result, etc.
//

import Foundation

/// Namespace for subscription upgrade offer types.
///
/// The upgrade offer presents a native sheet when a user is eligible to switch
/// from a shorter billing cycle to a longer one with savings. Developers customize
/// messaging via the ZeroSettle dashboard.
///
/// Access types via the namespace: `UpgradeOffer.Config`, `UpgradeOffer.Result`, etc.
public enum UpgradeOffer {

    // MARK: - Public Types

    /// Reason why an upgrade offer is not available.
    ///
    /// Unknown server values are preserved via `.other(String)` for forward compatibility.
    public enum IneligibilityReason: Sendable, Equatable, Hashable {
        case noActiveSubscription
        case alreadyHighestTier
        case other(String)

        /// The raw string value for serialization and logging.
        public var rawString: String {
            switch self {
            case .noActiveSubscription: return "no_active_subscription"
            case .alreadyHighestTier: return "already_highest_tier"
            case .other(let value): return value
            }
        }

        init(rawString: String) {
            switch rawString {
            case "no_active_subscription": self = .noActiveSubscription
            case "already_highest_tier": self = .alreadyHighestTier
            default: self = .other(rawString)
            }
        }
    }

    /// Configuration returned by the backend describing an available upgrade.
    public struct Config: Sendable {
        /// Whether an upgrade offer is available for this user/product.
        public let available: Bool
        /// Reason if not available.
        public let reason: IneligibilityReason?
        /// The user's current subscription product.
        public let currentProduct: ProductInfo?
        /// The upgrade target product.
        public let targetProduct: ProductInfo?
        /// Savings percentage (0–100).
        public let savingsPercent: Int?
        /// The type of upgrade path.
        public let upgradeType: UpgradeType?
        /// Proration details for web-to-web upgrades.
        public let proration: Proration?
        /// Display messaging customized from the dashboard.
        public let display: Display?
        /// A/B experiment variant identifier, if this config is part of an experiment.
        public let variantId: Int?
    }

    // Custom Codable for Config since IneligibilityReason needs raw string mapping
    // (extension below)

    /// Info about a subscription product in an upgrade offer (current or target).
    public struct ProductInfo: Sendable, Equatable {
        public let referenceId: String
        public let name: String
        public let price: Price
        public let billingLabel: String
        /// Monthly equivalent price for annual/multi-month plans. `nil` for the current product.
        public let monthlyEquivalent: Price?

        public init(
            referenceId: String,
            name: String,
            price: Price,
            billingLabel: String,
            monthlyEquivalent: Price? = nil
        ) {
            self.referenceId = referenceId
            self.name = name
            self.price = price
            self.billingLabel = billingLabel
            self.monthlyEquivalent = monthlyEquivalent
        }
    }

    /// The upgrade path type.
    public enum UpgradeType: String, Codable, Sendable {
        case webToWeb = "web_to_web"
        case storekitToWeb = "storekit_to_web"
    }

    /// Proration details for web-to-web upgrades.
    public struct Proration: Codable, Sendable {
        /// Credit or charge amount in cents (negative = credit).
        public let amountCents: Int
        /// Currency code.
        public let currency: String
        /// Next billing date after the upgrade.
        public let nextBillingDate: Date?
    }

    /// Messaging to display in the upgrade offer sheet.
    public struct Display: Codable, Sendable {
        public let title: String
        public let body: String
        public let ctaText: String
        public let dismissText: String
        /// Additional body text for StoreKit→Web migrations.
        public let storekitMigrationBody: String?
        /// Instructions for cancelling the Apple subscription.
        public let storekitCancelInstructions: String?
    }

    /// The outcome of an upgrade offer presentation.
    public enum Result: Sendable, Equatable {
        /// The user accepted and the upgrade was executed.
        case upgraded
        /// The user explicitly declined the offer.
        case declined
        /// The user dismissed the sheet without acting.
        case dismissed

        /// Wire-safe outcome name for submitting to the backend.
        internal var outcomeName: String {
            switch self {
            case .upgraded: return "upgraded"
            case .declined: return "declined"
            case .dismissed: return "dismissed"
            }
        }
    }

    // MARK: - Internal Types

    /// Request body for executing an upgrade.
    internal struct ExecuteRequest: Encodable {
        let userId: String
        let currentProductId: String
        let targetProductId: String
    }

    /// Request body for responding to an upgrade offer (declined/dismissed).
    internal struct RespondRequest: Encodable {
        let userId: String
        let currentProductId: String
        let targetProductId: String
        let outcome: String
        /// A/B experiment variant identifier echoed back from the config.
        let variantId: Int?
    }
}

// MARK: - UpgradeOffer.ProductInfo + Codable

extension UpgradeOffer.ProductInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case referenceId, name, priceCents, currency, billingLabel, monthlyEquivalentCents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceId = try container.decode(String.self, forKey: .referenceId)
        name = try container.decode(String.self, forKey: .name)
        let cents = try container.decode(Int.self, forKey: .priceCents)
        let currency = try container.decode(String.self, forKey: .currency)
        price = Price(amountCents: cents, currencyCode: currency)
        billingLabel = try container.decode(String.self, forKey: .billingLabel)
        if let monthlyCents = try container.decodeIfPresent(Int.self, forKey: .monthlyEquivalentCents) {
            monthlyEquivalent = Price(amountCents: monthlyCents, currencyCode: currency)
        } else {
            monthlyEquivalent = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(referenceId, forKey: .referenceId)
        try container.encode(name, forKey: .name)
        try container.encode(price.amountCents, forKey: .priceCents)
        try container.encode(price.currencyCode, forKey: .currency)
        try container.encode(billingLabel, forKey: .billingLabel)
        try container.encodeIfPresent(monthlyEquivalent?.amountCents, forKey: .monthlyEquivalentCents)
    }
}

// MARK: - UpgradeOffer.Config + Codable

extension UpgradeOffer.Config: Codable {
    private enum CodingKeys: String, CodingKey {
        case available, reason, currentProduct, targetProduct
        case savingsPercent, upgradeType, proration, display, variantId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decode(Bool.self, forKey: .available)
        if let rawReason = try container.decodeIfPresent(String.self, forKey: .reason) {
            reason = UpgradeOffer.IneligibilityReason(rawString: rawReason)
        } else {
            reason = nil
        }
        currentProduct = try container.decodeIfPresent(UpgradeOffer.ProductInfo.self, forKey: .currentProduct)
        targetProduct = try container.decodeIfPresent(UpgradeOffer.ProductInfo.self, forKey: .targetProduct)
        savingsPercent = try container.decodeIfPresent(Int.self, forKey: .savingsPercent)
        upgradeType = try container.decodeIfPresent(UpgradeOffer.UpgradeType.self, forKey: .upgradeType)
        proration = try container.decodeIfPresent(UpgradeOffer.Proration.self, forKey: .proration)
        display = try container.decodeIfPresent(UpgradeOffer.Display.self, forKey: .display)
        variantId = try container.decodeIfPresent(Int.self, forKey: .variantId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encodeIfPresent(reason?.rawString, forKey: .reason)
        try container.encodeIfPresent(currentProduct, forKey: .currentProduct)
        try container.encodeIfPresent(targetProduct, forKey: .targetProduct)
        try container.encodeIfPresent(savingsPercent, forKey: .savingsPercent)
        try container.encodeIfPresent(upgradeType, forKey: .upgradeType)
        try container.encodeIfPresent(proration, forKey: .proration)
        try container.encodeIfPresent(display, forKey: .display)
        try container.encodeIfPresent(variantId, forKey: .variantId)
    }
}
