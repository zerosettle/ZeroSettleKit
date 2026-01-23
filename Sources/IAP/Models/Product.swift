//
//  Product.swift
//  ZeroSettleIAP
//
//  Product models for web checkout offerings.
//

import Foundation

// MARK: - Product

/// A product available for web checkout via ZeroSettle.
/// The `id` matches the StoreKit product identifier configured on the ZeroSettle dashboard.
public struct Product: Identifiable, Sendable, Codable, Equatable {
    /// StoreKit product identifier (e.g., "com.app.premium_monthly")
    public let id: String

    /// Display name for the product
    public let displayName: String

    /// Product description
    public let productDescription: String

    /// The type of product (subscription, consumable, etc.)
    public let type: ProductType

    /// The web checkout price (may differ from App Store price)
    public let webPrice: Price

    /// Active promotion, if any
    public let promotion: Promotion?

    public init(
        id: String,
        displayName: String,
        productDescription: String,
        type: ProductType,
        webPrice: Price,
        promotion: Promotion? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.productDescription = productDescription
        self.type = type
        self.webPrice = webPrice
        self.promotion = promotion
    }
}

// MARK: - Product Type

/// The type of in-app purchase product.
public enum ProductType: String, Sendable, Codable {
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
