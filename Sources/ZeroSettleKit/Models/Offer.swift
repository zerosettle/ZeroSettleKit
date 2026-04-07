import Foundation

/// Unified offer namespace for both migration and upgrade flows.
/// The server resolves which offer type to show; the SDK renders it.
public enum Offer {

    /// The type of offer flow, determined by the server.
    public enum FlowType: String, Codable, Sendable {
        case migration
        case upgrade
    }

    /// The upgrade path type (only for upgrade flows).
    public enum UpgradeType: String, Codable, Sendable {
        case storekitToWeb = "storekit_to_web"
        case webToWeb = "web_to_web"
    }

    /// Lifecycle state of the offer.
    public enum State: Sendable, Equatable {
        case loading
        case ineligible
        case eligible
        case presented
        case accepted
        case completed
        case dismissed
    }

    /// Server-configurable display copy for every tip card state.
    /// Empty strings mean "use SDK default".
    public struct Display: Codable, Sendable, Equatable {
        public let offerTitle: String
        public let offerMessage: String
        public let offerCta: String
        public let acceptedTitle: String
        public let acceptedMessage: String
        public let acceptedCta: String
        public let completedTitle: String
        public let completedMessage: String

        // MARK: - Fallback Accessors

        public func offerTitleOrDefault(_ fallback: String) -> String {
            offerTitle.isEmpty ? fallback : offerTitle
        }
        public func offerMessageOrDefault(_ fallback: String) -> String {
            offerMessage.isEmpty ? fallback : offerMessage
        }
        public func offerCtaOrDefault(_ fallback: String) -> String {
            offerCta.isEmpty ? fallback : offerCta
        }
        public func acceptedTitleOrDefault(_ fallback: String) -> String {
            acceptedTitle.isEmpty ? fallback : acceptedTitle
        }
        public func acceptedMessageOrDefault(_ fallback: String) -> String {
            acceptedMessage.isEmpty ? fallback : acceptedMessage
        }
        public func acceptedCtaOrDefault(_ fallback: String) -> String {
            acceptedCta.isEmpty ? fallback : acceptedCta
        }
        public func completedTitleOrDefault(_ fallback: String) -> String {
            completedTitle.isEmpty ? fallback : completedTitle
        }
        public func completedMessageOrDefault(_ fallback: String) -> String {
            completedMessage.isEmpty ? fallback : completedMessage
        }
    }

    /// Per-product offer override.
    public struct PerProductOffer: Codable, Sendable, Equatable {
        public let productId: String
        public let savingsPercent: Int
        public let display: Display
    }

    /// The resolved offer data from the server's `offer` field in the products response.
    public struct OfferData: Sendable, Equatable {
        public let flowType: FlowType
        public let productId: String
        public let eligibleProductIds: [String]
        public let savingsPercent: Int
        public let display: Display

        // Migration-specific
        public let freeTrialDays: Int
        public let minSubscriptionDays: Int
        public let maxSubscriptionDays: Int?
        public let rolloutPercent: Int?

        // Upgrade-specific
        public let upgradeType: UpgradeType?
        public let fromProductId: String?
        public let toProductId: String?

        // Experiment
        public let variantId: Int?

        // Per-product overrides
        public let perProductPrompts: [String: PerProductOffer]?

        /// Whether this offer requires Apple subscription cancellation post-checkout.
        public var needsAppleCancel: Bool {
            switch flowType {
            case .migration:
                return true
            case .upgrade:
                return upgradeType == .storekitToWeb
            }
        }

        /// The target product ID for checkout (to_product_id for upgrades, product_id for migration).
        public var checkoutProductId: String {
            toProductId ?? productId
        }
    }
}

// MARK: - Codable

extension Offer.OfferData: Codable {
    private enum CodingKeys: String, CodingKey {
        case flowType, productId, eligibleProductIds, savingsPercent, display
        case freeTrialDays, minSubscriptionDays, maxSubscriptionDays, rolloutPercent
        case upgradeType, fromProductId, toProductId
        case variantId, perProductPrompts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flowType = try container.decode(Offer.FlowType.self, forKey: .flowType)
        productId = try container.decode(String.self, forKey: .productId)
        eligibleProductIds = try container.decodeIfPresent([String].self, forKey: .eligibleProductIds) ?? []
        savingsPercent = try container.decodeIfPresent(Int.self, forKey: .savingsPercent) ?? 0
        display = try container.decode(Offer.Display.self, forKey: .display)
        freeTrialDays = try container.decodeIfPresent(Int.self, forKey: .freeTrialDays) ?? 0
        minSubscriptionDays = try container.decodeIfPresent(Int.self, forKey: .minSubscriptionDays) ?? 0
        maxSubscriptionDays = try container.decodeIfPresent(Int.self, forKey: .maxSubscriptionDays)
        rolloutPercent = try container.decodeIfPresent(Int.self, forKey: .rolloutPercent)
        upgradeType = try container.decodeIfPresent(Offer.UpgradeType.self, forKey: .upgradeType)
        fromProductId = try container.decodeIfPresent(String.self, forKey: .fromProductId)
        toProductId = try container.decodeIfPresent(String.self, forKey: .toProductId)
        variantId = try container.decodeIfPresent(Int.self, forKey: .variantId)
        perProductPrompts = try container.decodeIfPresent([String: Offer.PerProductOffer].self, forKey: .perProductPrompts)
    }
}
