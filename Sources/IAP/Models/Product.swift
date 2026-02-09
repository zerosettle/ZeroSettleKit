//
//  Product.swift
//  ZeroSettleIAP
//
//  Product models for web checkout offerings.
//

import Foundation
import StoreKit

// MARK: - Product

/// A product available for web checkout via ZeroSettle.
/// The `id` matches the StoreKit product identifier configured on the ZeroSettle dashboard.
public struct ZSProduct: Identifiable, Sendable {
    /// StoreKit product identifier (e.g., "com.app.premium_monthly")
    public let id: String

    /// Display name for the product
    public let displayName: String

    /// Product description
    public let productDescription: String

    /// The type of product (subscription, consumable, etc.)
    public let type: ZSProductType

    /// The web checkout price (may differ from App Store price)
    public let webPrice: Price

    /// App Store price from the backend (for display purposes)
    public let appStorePrice: Price?

    /// Whether this product is synced to App Store Connect (available for StoreKit purchase)
    public let syncedToASC: Bool

    /// Active promotion, if any
    public let promotion: Promotion?

    /// The underlying StoreKit product (populated after reconciliation)
    internal var _storeKitProduct: StoreKit.Product?

    /// Whether StoreKit purchase is available for this product
    public var storeKitAvailable: Bool { _storeKitProduct != nil }

    /// StoreKit price - prefers on-device fetch, falls back to backend price for display
    public var storeKitPrice: Price? {
        if let skProduct = _storeKitProduct {
            let micros = Int((skProduct.price as NSDecimalNumber).doubleValue * 1_000_000)
            // Use web price currency as fallback since priceFormatStyle.currencyCode can crash
            return Price(amountMicros: micros, currencyCode: webPrice.currencyCode)
        }
        return appStorePrice
    }

    public init(
        id: String,
        displayName: String,
        productDescription: String,
        type: ZSProductType,
        webPrice: Price,
        appStorePrice: Price? = nil,
        syncedToASC: Bool = false,
        promotion: Promotion? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.productDescription = productDescription
        self.type = type
        self.webPrice = webPrice
        self.appStorePrice = appStorePrice
        self.syncedToASC = syncedToASC
        self.promotion = promotion
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
        case syncedToASC = "syncedToAsc"
        case promotion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        productDescription = try container.decode(String.self, forKey: .productDescription)
        type = try container.decode(ZSProductType.self, forKey: .type)
        webPrice = try container.decode(Price.self, forKey: .webPrice)
        appStorePrice = try container.decodeIfPresent(Price.self, forKey: .appStorePrice)
        syncedToASC = try container.decodeIfPresent(Bool.self, forKey: .syncedToASC) ?? false
        promotion = try container.decodeIfPresent(Promotion.self, forKey: .promotion)
        _storeKitProduct = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(productDescription, forKey: .productDescription)
        try container.encode(type, forKey: .type)
        try container.encode(webPrice, forKey: .webPrice)
        try container.encodeIfPresent(appStorePrice, forKey: .appStorePrice)
        try container.encode(syncedToASC, forKey: .syncedToASC)
        try container.encodeIfPresent(promotion, forKey: .promotion)
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
        lhs.syncedToASC == rhs.syncedToASC &&
        lhs.promotion == rhs.promotion
    }
}

// MARK: - Product Type

/// The type of in-app purchase product.
public enum ZSProductType: String, Sendable, Codable {
    case autoRenewableSubscription = "auto_renewable_subscription"
    case nonRenewingSubscription = "non_renewing_subscription"
    case consumable = "consumable"
    case nonConsumable = "non_consumable"
}

// MARK: - Price

/// A price with currency information.
public struct Price: Sendable, Codable, Equatable {
    /// Price in micros (e.g., 9990000 = $9.99). 1 unit = 1/1,000,000 of the currency.
    public let amountMicros: Int

    /// ISO 4217 currency code (e.g., "USD")
    public let currencyCode: String

    public init(amountMicros: Int, currencyCode: String) {
        self.amountMicros = amountMicros
        self.currencyCode = currencyCode
    }

    /// Formatted price string (e.g., "$9.99")
    public var formatted: String {
        let amount = Double(amountMicros) / 1_000_000.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currencyCode) \(String(format: "%.2f", amount))"
    }
}
