//
//  UserOffer.swift
//  ZeroSettleKit
//
//  Unified /v1/iap/user-offer/ response schema (SDK 1.2+).
//  Additive — apps still consuming /v1/iap/products/'s config.offer continue
//  to work unchanged. Apps that adopt 1.2+ can call
//  `ZeroSettle.shared.fetchUserOffer(userId:)` to get a canonical offer
//  decision without client-side rollout re-hashing.
//

import Foundation

/// Namespace for the unified /v1/iap/user-offer/ response schema (SDK 1.2+).
///
/// Access types via the namespace: `UserOffer.Response`, `UserOffer.ActionType`, etc.
public enum UserOffer {

    /// Top-level response from `GET /v1/iap/user-offer/`.
    public struct Response: Codable, Equatable, Sendable {
        public let userId: String
        public let appId: Int
        public let isSandbox: Bool
        public let subscription: Subscription
        public let offer: OfferData
        public let serverTime: Date
    }

    /// Tagged union keyed by wire `"type"`. Unknown types decode as
    /// ``Subscription/unknown(_:)`` for forward compatibility.
    public enum Subscription: Codable, Equatable, Sendable {
        case none
        case activeWeb(ActiveWeb)
        case activeStorekit(ActiveStorekit)
        case migrationTrial(MigrationTrial)
        case cancelledActive(CancelledActive)
        case unknown(String)

        public struct ActiveWeb: Codable, Equatable, Sendable {
            public let productId: String
        }

        public struct ActiveStorekit: Codable, Equatable, Sendable {
            public let productId: String
        }

        public struct MigrationTrial: Codable, Equatable, Sendable {
            public let productId: String
        }

        public struct CancelledActive: Codable, Equatable, Sendable {
            public let productId: String
        }

        private enum CodingKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "none":
                self = .none
            case "active_web":
                self = .activeWeb(try ActiveWeb(from: decoder))
            case "active_storekit":
                self = .activeStorekit(try ActiveStorekit(from: decoder))
            case "migration_trial":
                self = .migrationTrial(try MigrationTrial(from: decoder))
            case "cancelled_active":
                self = .cancelledActive(try CancelledActive(from: decoder))
            default:
                self = .unknown(type)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .none:
                try container.encode("none", forKey: .type)
            case .activeWeb(let value):
                try container.encode("active_web", forKey: .type)
                try value.encode(to: encoder)
            case .activeStorekit(let value):
                try container.encode("active_storekit", forKey: .type)
                try value.encode(to: encoder)
            case .migrationTrial(let value):
                try container.encode("migration_trial", forKey: .type)
                try value.encode(to: encoder)
            case .cancelledActive(let value):
                try container.encode("cancelled_active", forKey: .type)
                try value.encode(to: encoder)
            case .unknown(let rawType):
                try container.encode(rawType, forKey: .type)
            }
        }
    }

    /// Canonical offer payload. The `actionType` discriminates between no-action,
    /// migration, and two upgrade flows.
    public struct OfferData: Codable, Equatable, Sendable {
        public let actionType: ActionType
        public let isEligible: Bool
        public let checkoutProductId: String
        public let fromProductId: String?
        public let savingsPercent: Int
        public let freeTrialDays: Int
        public let minSubscriptionDays: Int
        public let display: Display?
        public let proration: Proration?
        public let requiresAppleCancel: Bool
        public let appleSubscription: AppleSubscription?
        public let checkoutPresentation: CheckoutPresentation?
        public let experimentVariantId: Int?
    }

    /// Discriminator for the resolved action.
    public enum ActionType: String, Codable, Equatable, Sendable {
        case noAction = "no_action"
        case migrateStorekitToWeb = "migrate_storekit_to_web"
        case upgradeStorekitToWeb = "upgrade_storekit_to_web"
        case upgradeWebToWeb = "upgrade_web_to_web"
    }

    /// Display copy for every offer lifecycle state.
    public struct Display: Codable, Equatable, Sendable {
        public let title: String
        public let body: String
        public let ctaText: String
        public let dismissText: String
        public let acceptedTitle: String
        public let acceptedBody: String
        public let completedTitle: String
        public let completedBody: String
        public let appleCancelInstructions: String
    }

    /// Proration details for web-to-web upgrades.
    public struct Proration: Codable, Equatable, Sendable {
        public let amountCents: Int
        public let currency: String
        public let nextBillingDate: Date?
    }

    /// Real-time Apple subscription status, when applicable.
    public struct AppleSubscription: Codable, Equatable, Sendable {
        public let isActive: Bool
        public let expiresAt: Date?
        public let statusCode: Int
        public let autoRenewEnabled: Bool
    }

    /// How the server recommends presenting checkout when the CTA is tapped.
    public enum CheckoutPresentation: String, Codable, Equatable, Sendable {
        case webview
        case nativePay = "native_pay"
        case safariVc = "safari_vc"
        case safari
    }
}
