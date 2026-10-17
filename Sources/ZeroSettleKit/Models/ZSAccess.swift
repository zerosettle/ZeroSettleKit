//
//  ZSAccess.swift
//  ZeroSettleKit
//
//  Plan, add-ons, feature values and balances returned on the entitlements read.
//  These are decoded with a plain JSONDecoder and explicit CodingKeys, never the
//  shared snake-case decoder, so developer-chosen feature keys keep their form.
//

import Foundation
internal import ZeroSettleCore

/// Whether a ``ZSPlan`` is a base tier or an add-on.
public enum ZSPlanKind: String, Codable, Sendable {
    case tier
    case addOn = "add_on"
    /// A kind this SDK version does not know about.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ZSPlanKind(rawValue: raw) ?? .unknown
    }
}

/// A plan or add-on a person is on.
public struct ZSPlan: Codable, Sendable, Equatable, Hashable {
    public let key: String
    public let name: String
    public let kind: ZSPlanKind

    public init(key: String, name: String, kind: ZSPlanKind) {
        self.key = key
        self.name = name
        self.kind = kind
    }
}

/// The value of a feature: on/off, or a text value such as a quality level.
public enum ZSFeatureValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            throw DecodingError.typeMismatch(
                ZSFeatureValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a bool or a string")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .text(let text): try container.encode(text)
        }
    }
}

/// A spendable currency, as summarized on a balance.
public struct ZSCurrency: Codable, Sendable, Equatable {
    public let key: String
    public let name: String
    public let plural: String
    /// A Lucide icon name.
    public let glyph: String
    /// What to answer while ZeroSettle cannot be reached: `allow` or `stop`.
    public let offline: String

    public init(key: String, name: String, plural: String, glyph: String, offline: String) {
        self.key = key
        self.name = name
        self.plural = plural
        self.glyph = glyph
        self.offline = offline
    }
}

/// What a person has left to spend in one currency.
public struct ZSBalance: Codable, Sendable, Equatable {
    public let currency: ZSCurrency
    /// Everything spendable now: allowance left, rolled over and purchased, minus open holds.
    public let remaining: Int
    /// This period's allowance, or nil when the person has none in this currency.
    public let limit: Int?
    /// The earliest next refill, or nil when nothing resets.
    public let resetsAt: Date?
    public let allowanceRemaining: Int
    public let rolledOver: Int
    public let purchased: Int

    public init(
        currency: ZSCurrency,
        remaining: Int,
        limit: Int?,
        resetsAt: Date?,
        allowanceRemaining: Int,
        rolledOver: Int,
        purchased: Int
    ) {
        self.currency = currency
        self.remaining = remaining
        self.limit = limit
        self.resetsAt = resetsAt
        self.allowanceRemaining = allowanceRemaining
        self.rolledOver = rolledOver
        self.purchased = purchased
    }

    private enum CodingKeys: String, CodingKey {
        case currency, remaining, limit, purchased
        case resetsAt = "resets_at"
        case allowanceRemaining = "allowance_remaining"
        case rolledOver = "rolled_over"
    }
}

/// A person's plan, add-ons, feature values and balances.
public struct ZSAccess: Codable, Sendable, Equatable {
    public let plan: ZSPlan?
    public let addOns: [ZSPlan]
    public let features: [String: ZSFeatureValue]
    public let balances: [String: ZSBalance]
    /// False when the response carried none of the four keys (an old backend, or
    /// a failed server-side resolve). Callers keep their last-known value then.
    public let isPresent: Bool

    public static let empty = ZSAccess(plan: nil, addOns: [], features: [:], balances: [:], isPresent: false)

    public init(
        plan: ZSPlan?,
        addOns: [ZSPlan],
        features: [String: ZSFeatureValue],
        balances: [String: ZSBalance],
        isPresent: Bool = true
    ) {
        self.plan = plan
        self.addOns = addOns
        self.features = features
        self.balances = balances
        self.isPresent = isPresent
    }

    private enum CodingKeys: String, CodingKey {
        case plan, features, balances
        case addOns = "add_ons"
    }

    /// Decodes a feature value, yielding nil for JSON that is neither a bool nor a string.
    private struct LossyFeature: Decodable {
        let value: ZSFeatureValue?
        init(from decoder: Decoder) throws {
            value = try? ZSFeatureValue(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decodeIfPresent(ZSPlan.self, forKey: .plan)
        addOns = try container.decodeIfPresent([ZSPlan].self, forKey: .addOns) ?? []
        let lossy = try container.decodeIfPresent([String: LossyFeature].self, forKey: .features) ?? [:]
        features = lossy.compactMapValues { $0.value }
        balances = try container.decodeIfPresent([String: ZSBalance].self, forKey: .balances) ?? [:]
        isPresent = [CodingKeys.plan, .addOns, .features, .balances].contains { container.contains($0) }
    }

    public func encode(to encoder: Encoder) throws {
        guard isPresent else { return }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encode(addOns, forKey: .addOns)
        try container.encode(features, forKey: .features)
        try container.encode(balances, forKey: .balances)
    }

    /// Decodes the access part of an entitlements response from its raw bytes.
    /// Returns ``empty`` when the bytes carry none of the four keys or cannot be read.
    static func decode(from data: Data) -> ZSAccess {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ZSAccess.self, from: data)
        } catch {
            ZSLogger.error("Access decoding failed: \(error)", category: .entitlements)
            return .empty
        }
    }
}
