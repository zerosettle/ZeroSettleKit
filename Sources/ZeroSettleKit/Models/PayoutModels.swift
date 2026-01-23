import Foundation

/// Normalized representation of an app-specific payout table
public struct ZeroSettlePayoutTable: Sendable {
    /// Internal database identifier for the payout table record
    public let id: Int

    /// The partner app identifier that owns this payout table
    public let appId: Int

    /// Human readable name shown in partner dashboard
    public let name: String

    /// Incrementing version number (1-based)
    public let version: Int

    /// Current status (e.g., `active`, `draft`, `archived`)
    public let status: String

    /// ISO8601 timestamp string for when this version was created
    public let createdAt: String

    /// Normalized tier list, sorted by guesses used ascending
    public let tiers: [PayoutTier]

    public init(
        id: Int,
        appId: Int,
        name: String,
        version: Int,
        status: String,
        createdAt: String,
        tiers: [PayoutTier]
    ) {
        self.id = id
        self.appId = appId
        self.name = name
        self.version = version
        self.status = status
        self.createdAt = createdAt
        self.tiers = tiers.sorted { $0.guessesUsed < $1.guessesUsed }
    }
}

/// A normalized payout tier for Wordle-style payouts
public struct PayoutTier: Codable, Hashable, Sendable {
    /// Number of guesses used to win
    public let guessesUsed: Int

    /// Multiplier applied to the wager
    public let multiplier: Double

    /// Optional human readable description
    public let description: String?

    public init(guessesUsed: Int, multiplier: Double, description: String? = nil) {
        self.guessesUsed = guessesUsed
        self.multiplier = multiplier
        self.description = description
    }
}

// MARK: - DTOs from API

struct PartnerPayoutResponse: Decodable {
    let app: PartnerAppSummary
    let payoutTable: PartnerPayoutTableDTO

    enum CodingKeys: String, CodingKey {
        case app
        case payoutTable = "payout_table"
    }
}

struct PartnerAppSummary: Decodable {
    let id: Int
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}

struct PartnerPayoutTableDTO: Decodable {
    let id: Int
    let appId: Int
    let name: String
    let version: Int
    let status: String
    let createdAt: String
    let payouts: [String: PayoutValue]

    enum CodingKeys: String, CodingKey {
        case id
        case appId = "app_id"
        case name
        case version
        case status
        case createdAt = "created_at"
        case payouts
    }

    func toDomainModel(descriptionProvider: (Int) -> String?) -> ZeroSettlePayoutTable {
        let tiers = payouts.compactMap { key, value -> PayoutTier? in
            guard let guesses = Int(key) else {
                return nil
            }
            return PayoutTier(
                guessesUsed: guesses,
                multiplier: value.multiplier,
                description: descriptionProvider(guesses)
            )
        }

        return ZeroSettlePayoutTable(
            id: id,
            appId: appId,
            name: name,
            version: version,
            status: status,
            createdAt: createdAt,
            tiers: tiers
        )
    }
}

enum PayoutValue: Decodable {
    case number(Double)
    case object(PayoutMultiplier)

    init(from decoder: Decoder) throws {
        if let doubleValue = try? decoder.singleValueContainer().decode(Double.self) {
            self = .number(doubleValue)
            return
        }

        if let objectValue = try? decoder.singleValueContainer().decode(PayoutMultiplier.self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.typeMismatch(
            PayoutValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected Double or { \"multiplier\": Double }"
            )
        )
    }

    var multiplier: Double {
        switch self {
        case .number(let value):
            return value
        case .object(let object):
            return object.multiplier
        }
    }
}

struct PayoutMultiplier: Decodable {
    let multiplier: Double
}

