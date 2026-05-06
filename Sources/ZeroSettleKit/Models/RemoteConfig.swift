//
//  RemoteConfig.swift
//  ZeroSettleKit
//
//  Remote configuration types for checkout behavior and migration campaigns.
//

import Foundation

// MARK: - Jurisdiction

/// Geographic jurisdiction for checkout configuration.
/// The SDK detects the user's jurisdiction via StoreKit's `Storefront.current`
/// and applies the matching override (or falls back to the global default).
public enum Jurisdiction: String, Codable, Sendable, CaseIterable {
    case us
    case eu
    case row

    /// Map a StoreKit storefront country code to a jurisdiction.
    /// Accepts both ISO 3166-1 alpha-3 (from StoreKit 2) and alpha-2 codes.
    public static func from(storefrontCountryCode code: String) -> Jurisdiction {
        let upper = code.uppercased()
        if upper == "USA" || upper == "US" { return .us }
        if euAlpha3Codes.contains(upper) || euAlpha2Codes.contains(upper) { return .eu }
        return .row
    }

    /// EU member state ISO 3166-1 alpha-3 codes (StoreKit 2 uses these).
    private static let euAlpha3Codes: Set<String> = [
        "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST",
        "FIN", "FRA", "DEU", "GRC", "HUN", "IRL", "ITA", "LVA",
        "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK",
        "SVN", "ESP", "SWE",
    ]

    /// EU member state ISO 3166-1 alpha-2 codes (fallback).
    private static let euAlpha2Codes: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE",
        "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV",
        "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK",
        "SI", "ES", "SE",
    ]
}

// MARK: - Jurisdiction Checkout Config

/// Per-jurisdiction checkout configuration override.
public struct JurisdictionCheckoutConfig: Sendable, Equatable {
    /// The checkout sheet type for this jurisdiction
    public let sheetType: CheckoutType

    /// Whether web checkout is enabled for this jurisdiction
    public let isEnabled: Bool

    public init(sheetType: CheckoutType, isEnabled: Bool) {
        self.sheetType = sheetType
        self.isEnabled = isEnabled
    }
}

// MARK: - Checkout Type

/// The type of checkout UI to present.
/// Configured remotely via the ZeroSettle dashboard.
public enum CheckoutType: String, Codable, Sendable {
    /// Embedded WKWebView within the app
    case webView = "webview"

    /// In-app SFSafariViewController
    case safariVC = "safari_vc"

    /// External Safari browser
    case safari = "safari"

    /// Native Apple Pay sheet via STPApplePayContext (requires `NativePay` package trait).
    /// Falls back to `.webView` when the trait is not enabled or Apple Pay is unavailable.
    case nativePay = "native_pay"
}

// MARK: - Checkout Config

/// Configuration for the checkout UI behavior.
public struct CheckoutConfig: Sendable, Equatable {
    /// The global default checkout sheet type
    public let sheetType: CheckoutType

    /// Whether web checkout is enabled globally
    public let isEnabled: Bool

    /// Per-jurisdiction overrides (empty if no overrides configured)
    public let jurisdictions: [Jurisdiction: JurisdictionCheckoutConfig]

    /// Apple Pay merchant identifier provided by the backend (managed mode default).
    /// The SDK prefers the local `Configuration.appleMerchantId` over this value.
    public let appleMerchantId: String?

    /// Allowed payment methods for this merchant. `nil` (or missing on the
    /// wire) means no restriction — all methods enabled by the merchant on
    /// the backend are available. `["apple_pay"]` restricts the SDK to
    /// Apple-Pay-only behavior (native availability checks, setup CTA,
    /// hide-when-unavailable). Other values are accepted for forward
    /// compatibility but trigger no v1.4.0 behavior change.
    public let paymentMethods: [String]?

    public init(
        sheetType: CheckoutType,
        isEnabled: Bool,
        jurisdictions: [Jurisdiction: JurisdictionCheckoutConfig] = [:],
        appleMerchantId: String? = nil,
        paymentMethods: [String]? = nil
    ) {
        self.sheetType = sheetType
        self.isEnabled = isEnabled
        self.jurisdictions = jurisdictions
        self.appleMerchantId = appleMerchantId
        self.paymentMethods = paymentMethods
    }

    /// True when the merchant has restricted payment to Apple Pay only.
    /// Drives native availability checks and banner CTA swap.
    public var isApplePayOnly: Bool {
        paymentMethods == ["apple_pay"]
    }
}

// MARK: - Migration Prompt

/// Data for a migration campaign prompt.
/// Shown to eligible StoreKit subscribers to encourage switching to web checkout.
public struct MigrationPrompt: Codable, Sendable, Equatable {
    /// The default product ID for this campaign (first in eligible list)
    public let productId: String

    /// The StoreKit product IDs eligible for this migration campaign.
    /// The SDK matches the user's active StoreKit subscription against this list.
    /// Defaults to `[productId]` when the backend doesn't provide the field.
    public let eligibleProductIds: [String]

    /// The discount percentage offered (e.g., 20 for 20% off)
    public let discountPercent: Int

    /// Minimum subscription tenure (days) to show the prompt. 0 = no minimum.
    public let minSubscriptionDays: Int

    /// Maximum subscription tenure (days) to show the prompt. nil = no upper limit.
    public let maxSubscriptionDays: Int?

    /// Approximate number of free trial days for the migration checkout.
    /// Provided by the backend based on the remaining StoreKit subscription period.
    /// Defaults to 0 if the backend doesn't provide this field.
    public let freeTrialDays: Int

    /// The title to display in the migration prompt
    public let title: String

    /// The message body to display in the migration prompt
    public let message: String

    /// The CTA button text to display in the migration prompt
    public let ctaText: String

    /// Rollout percentage (0-100). When less than 100, only a deterministic subset
    /// of users (based on hashed userId) will see the migration prompt.
    /// Defaults to 100 (all users) when not provided by the backend.
    public let rolloutPercent: Int?

    /// Per-product prompt data keyed by product ID.
    /// When present, provides product-specific discount and text overrides.
    public let perProductPrompts: [String: PerProductData]?

    /// Per-product prompt data with product-specific discount and interpolated text.
    public struct PerProductData: Codable, Sendable, Equatable {
        public let discountPercent: Int
        public let title: String
        public let message: String
        public let ctaText: String

        public init(discountPercent: Int, title: String, message: String, ctaText: String) {
            self.discountPercent = discountPercent
            self.title = title
            self.message = message
            self.ctaText = ctaText
        }
    }

    public init(productId: String, eligibleProductIds: [String] = [], discountPercent: Int, minSubscriptionDays: Int = 0, maxSubscriptionDays: Int? = nil, freeTrialDays: Int = 0, title: String, message: String, ctaText: String, rolloutPercent: Int? = nil, perProductPrompts: [String: PerProductData]? = nil) {
        self.productId = productId
        self.eligibleProductIds = eligibleProductIds
        self.discountPercent = discountPercent
        self.minSubscriptionDays = minSubscriptionDays
        self.maxSubscriptionDays = maxSubscriptionDays
        self.freeTrialDays = freeTrialDays
        self.title = title
        self.message = message
        self.ctaText = ctaText
        self.rolloutPercent = rolloutPercent
        self.perProductPrompts = perProductPrompts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productId = try container.decode(String.self, forKey: .productId)
        eligibleProductIds = try container.decodeIfPresent([String].self, forKey: .eligibleProductIds) ?? []
        discountPercent = try container.decode(Int.self, forKey: .discountPercent)
        minSubscriptionDays = try container.decodeIfPresent(Int.self, forKey: .minSubscriptionDays) ?? 0
        maxSubscriptionDays = try container.decodeIfPresent(Int.self, forKey: .maxSubscriptionDays)
        freeTrialDays = try container.decodeIfPresent(Int.self, forKey: .freeTrialDays) ?? 0
        title = try container.decode(String.self, forKey: .title)
        message = try container.decode(String.self, forKey: .message)
        ctaText = try container.decodeIfPresent(String.self, forKey: .ctaText) ?? "Switch Now"
        rolloutPercent = try container.decodeIfPresent(Int.self, forKey: .rolloutPercent)
        perProductPrompts = try container.decodeIfPresent([String: PerProductData].self, forKey: .perProductPrompts)
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

    /// Unified offer data (new — preferred over `migration` when available)
    public let offer: Offer.OfferData?

    public init(checkout: CheckoutConfig, migration: MigrationPrompt?, offer: Offer.OfferData? = nil) {
        self.checkout = checkout
        self.migration = migration
        self.offer = offer
    }
}
