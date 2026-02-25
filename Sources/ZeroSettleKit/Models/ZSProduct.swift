//
//  ZSProduct.swift
//  ZeroSettleKit
//
//  Product models for web checkout offerings.
//

import Foundation
import StoreKit

// MARK: - ZSProduct

/// A product available for web checkout via ZeroSettle.
/// The `id` matches the StoreKit product identifier configured on the ZeroSettle dashboard.
public struct ZSProduct: Identifiable, Sendable {

    // MARK: - Nested Types

    /// The type of in-app purchase product.
    public enum ProductType: String, Sendable, Codable {
        case autoRenewableSubscription = "auto_renewable_subscription"
        case nonRenewingSubscription = "non_renewing_subscription"
        case consumable = "consumable"
        case nonConsumable = "non_consumable"
    }

    // MARK: - Properties

    /// StoreKit product identifier (e.g., "com.app.premium_monthly")
    public let id: String

    /// Display name for the product
    public let displayName: String

    /// Product description
    public let productDescription: String

    /// The type of product (subscription, consumable, etc.)
    public let type: ProductType

    /// The web checkout price (may differ from App Store price). `nil` when web checkout is not configured.
    public let webPrice: Price?

    /// App Store price from the backend (for display purposes)
    public let appStorePrice: Price?

    /// Whether this product is synced to App Store Connect (available for StoreKit purchase)
    public let syncedToAppStoreConnect: Bool

    /// Active promotion, if any
    public let promotion: Promotion?

    /// Subscription group identifier (non-nil for grouped subscriptions)
    public let subscriptionGroupId: Int?

    /// The underlying StoreKit product (populated after reconciliation)
    internal var _storeKitProduct: StoreKit.Product?

    /// Whether StoreKit purchase is available for this product
    public var storeKitAvailable: Bool { _storeKitProduct != nil }

    /// StoreKit price - prefers on-device fetch, falls back to backend price for display
    public var storeKitPrice: Price? {
        if let skProduct = _storeKitProduct {
            let cents = Int(((skProduct.price as NSDecimalNumber).doubleValue * 100).rounded())
            let currency = webPrice?.currencyCode ?? appStorePrice?.currencyCode ?? "USD"
            return Price(amountCents: cents, currencyCode: currency)
        }
        return appStorePrice
    }

    /// The percentage savings of the web price compared to the App Store price.
    /// Returns `nil` if the StoreKit price isn't available or web is more expensive.
    /// Example: StoreKit = $9.99, web = $6.99 → `savingsPercent` = 30
    public var savingsPercent: Int? {
        guard let webPrice, let skPrice = storeKitPrice, skPrice.amountCents > 0 else { return nil }
        let savings = Double(skPrice.amountCents - webPrice.amountCents) / Double(skPrice.amountCents)
        let percent = Int((savings * 100).rounded())
        return percent > 0 ? percent : nil
    }

    public init(
        id: String,
        displayName: String,
        productDescription: String,
        type: ProductType,
        webPrice: Price? = nil,
        appStorePrice: Price? = nil,
        syncedToAppStoreConnect: Bool = false,
        promotion: Promotion? = nil,
        subscriptionGroupId: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.productDescription = productDescription
        self.type = type
        self.webPrice = webPrice
        self.appStorePrice = appStorePrice
        self.syncedToAppStoreConnect = syncedToAppStoreConnect
        self.promotion = promotion
        self.subscriptionGroupId = subscriptionGroupId
        self._storeKitProduct = nil
    }
}

// MARK: - Codable

extension ZSProduct: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case productDescription
        case type
        case webPrice
        case appStorePrice = "storekitPrice"
        case syncedToAppStoreConnect = "syncedToAsc"
        case promotion
        case subscriptionGroupId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        productDescription = try container.decode(String.self, forKey: .productDescription)
        type = try container.decode(ProductType.self, forKey: .type)
        webPrice = try container.decodeIfPresent(Price.self, forKey: .webPrice)
        appStorePrice = try container.decodeIfPresent(Price.self, forKey: .appStorePrice)
        syncedToAppStoreConnect = try container.decodeIfPresent(Bool.self, forKey: .syncedToAppStoreConnect) ?? false
        promotion = try container.decodeIfPresent(Promotion.self, forKey: .promotion)
        subscriptionGroupId = try container.decodeIfPresent(Int.self, forKey: .subscriptionGroupId)
        _storeKitProduct = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(productDescription, forKey: .productDescription)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(webPrice, forKey: .webPrice)
        try container.encodeIfPresent(appStorePrice, forKey: .appStorePrice)
        try container.encode(syncedToAppStoreConnect, forKey: .syncedToAppStoreConnect)
        try container.encodeIfPresent(promotion, forKey: .promotion)
        try container.encodeIfPresent(subscriptionGroupId, forKey: .subscriptionGroupId)
    }
}

// MARK: - Equatable

extension ZSProduct: Equatable {
    public static func == (lhs: ZSProduct, rhs: ZSProduct) -> Bool {
        // Compare all codable properties (ignoring internal _storeKitProduct)
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.productDescription == rhs.productDescription &&
        lhs.type == rhs.type &&
        lhs.webPrice == rhs.webPrice &&
        lhs.appStorePrice == rhs.appStorePrice &&
        lhs.syncedToAppStoreConnect == rhs.syncedToAppStoreConnect &&
        lhs.promotion == rhs.promotion &&
        lhs.subscriptionGroupId == rhs.subscriptionGroupId
    }
}

// MARK: - Price

/// A price with currency information.
///
/// All amounts are in **cents** (e.g., 999 = $9.99), consistent with Stripe conventions.
/// The backend sends amounts in micros; the custom `Codable` implementation converts
/// automatically so callers always work with cents.
public struct Price: Sendable, Equatable {
    /// Price in cents (e.g., 999 = $9.99).
    public let amountCents: Int

    /// ISO 4217 currency code (e.g., "USD")
    public let currencyCode: String

    public init(amountCents: Int, currencyCode: String) {
        self.amountCents = amountCents
        self.currencyCode = currencyCode
    }

    /// Convenience initializer that converts from micros (backend wire format) to cents.
    public init(amountMicros: Int, currencyCode: String) {
        self.amountCents = Int((Double(amountMicros) / 10_000.0).rounded())
        self.currencyCode = currencyCode
    }

    /// Formatted price string (e.g., "$9.99")
    public var formatted: String {
        let amount = Double(amountCents) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currencyCode) \(String(format: "%.2f", amount))"
    }
}

// MARK: - Price + Codable

extension Price: Codable {
    private enum CodingKeys: String, CodingKey {
        case amountCents = "amountMicros"
        case currencyCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let micros = try container.decode(Int.self, forKey: .amountCents)
        amountCents = Int((Double(micros) / 10_000.0).rounded())
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Convert cents back to micros for round-trip fidelity with backend
        try container.encode(amountCents * 10_000, forKey: .amountCents)
        try container.encode(currencyCode, forKey: .currencyCode)
    }
}
