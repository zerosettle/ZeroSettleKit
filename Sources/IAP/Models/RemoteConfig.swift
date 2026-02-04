//
//  RemoteConfig.swift
//  ZeroSettleIAP
//
//  Remote configuration types for checkout behavior and migration campaigns.
//

import Foundation

// MARK: - Checkout Type

/// The type of checkout UI to present.
/// Configured remotely via the ZeroSettle dashboard.
public enum CheckoutType: String, Codable, Sendable {
    /// Embedded WKWebView within the app (requires ZeroSettleCheckoutView)
    case webview = "webview"

    /// In-app SFSafariViewController
    case safariVC = "safari_vc"

    /// External Safari browser
    case safari = "safari"
}

// MARK: - Checkout Config

/// Configuration for the checkout UI behavior.
public struct CheckoutConfig: Codable, Sendable, Equatable {
    /// The type of checkout sheet to present
    public let sheetType: CheckoutType

    /// Whether web checkout is enabled for this app
    public let isEnabled: Bool

    public init(sheetType: CheckoutType, isEnabled: Bool) {
        self.sheetType = sheetType
        self.isEnabled = isEnabled
    }
}

// MARK: - Migration Prompt

/// Data for a migration campaign prompt.
/// Shown to eligible StoreKit subscribers to encourage switching to web checkout.
public struct MigrationPrompt: Codable, Sendable, Equatable {
    /// The product ID to offer for migration
    public let productId: String

    /// The discount percentage offered (e.g., 20 for 20% off)
    public let discountPercent: Int

    /// The title to display in the migration prompt
    public let title: String

    /// The message body to display in the migration prompt
    public let message: String

    public init(productId: String, discountPercent: Int, title: String, message: String) {
        self.productId = productId
        self.discountPercent = discountPercent
        self.title = title
        self.message = message
    }
}

// MARK: - Remote Config

/// Remote configuration from the ZeroSettle backend.
/// Contains checkout behavior settings and optional migration campaign data.
public struct RemoteConfig: Sendable, Equatable {
    /// Checkout UI configuration
    public let checkout: CheckoutConfig

    /// Migration prompt data (nil if user not eligible or no active campaign)
    public let migration: MigrationPrompt?

    public init(checkout: CheckoutConfig, migration: MigrationPrompt?) {
        self.checkout = checkout
        self.migration = migration
    }
}
