//
//  ProductCatalog.swift
//  ZeroSettleKit
//
//  The result of fetching the product catalog from the ZeroSettle backend.
//

import Foundation

/// The result of fetching the product catalog.
/// Contains both the product list and any remote configuration returned by the backend in a single response.
public struct ProductCatalog: Sendable, Equatable {
    /// Products with web prices, StoreKit prices, and any active promotions.
    public let products: [ZSProduct]

    /// Remote configuration (checkout type, migration campaign, etc.).
    /// Non-nil when `userId` was passed to `fetchProducts(userId:)`.
    public let config: RemoteConfig?

    public init(products: [ZSProduct], config: RemoteConfig?) {
        self.products = products
        self.config = config
    }
}
