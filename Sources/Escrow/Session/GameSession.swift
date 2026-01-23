//
//  GameSession.swift
//  ZeroSettleEscrow
//
//  Models for game session management.
//  Supports single player, duels (2 players), and tournaments.
//

import Foundation
import ZeroSettleCore

// MARK: - Game Definition

/// A game definition from the ZeroSettle platform.
public struct GameDefinition: Sendable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let displayName: String
    public let description: String?
    public let payoutTable: PayoutTable

    public init(
        id: UUID,
        name: String,
        displayName: String,
        description: String? = nil,
        payoutTable: PayoutTable
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.payoutTable = payoutTable
    }
}

// MARK: - Payout Table

/// Payout configuration for a game.
public enum PayoutTable: Sendable, Codable {
    /// Discrete payouts - fixed multipliers for specific outcomes (e.g., Wordle)
    case discrete(DiscretePayoutTable)

    /// Continuous payouts - multiplier calculated from a curve (e.g., score-based games)
    case continuous(ContinuousPayoutTable)

    /// Maximum possible multiplier
    public var maxMultiplier: Double {
        switch self {
        case .discrete(let table):
            return table.maxMultiplier
        case .continuous(let table):
            return table.maxMultiplier
        }
    }

    /// Calculate multiplier for a given score/outcome value
    public func multiplier(for value: Double) -> Double {
        switch self {
        case .discrete(let table):
            return table.multiplier(for: Int(value))
        case .continuous(let table):
            return table.multiplier(for: value)
        }
    }
}

/// Discrete payout table - maps integer outcomes to fixed multipliers.
/// Used for games like Wordle where outcomes are countable (1-6 guesses).
public struct DiscretePayoutTable: Sendable, Codable {
    public let id: UUID
    public let entries: [DiscretePayoutEntry]

    public init(id: UUID, entries: [DiscretePayoutEntry]) {
        self.id = id
        self.entries = entries.sorted { $0.outcome < $1.outcome }
    }

    public var maxMultiplier: Double {
        entries.map(\.multiplier).max() ?? 0.0
    }

    public func multiplier(for outcome: Int) -> Double {
        entries.first { $0.outcome == outcome }?.multiplier ?? 0.0
    }
}

/// A single entry in a discrete payout table.
public struct DiscretePayoutEntry: Sendable, Codable {
    /// The outcome value (e.g., number of guesses, rounds, etc.)
    public let outcome: Int

    /// The payout multiplier for this outcome
    public let multiplier: Double

    public init(outcome: Int, multiplier: Double) {
        self.outcome = outcome
        self.multiplier = multiplier
    }
}

/// Continuous payout table - calculates multiplier from a curve function.
/// Used for score-based games like 2048 where any score is possible.
public struct ContinuousPayoutTable: Sendable, Codable {
    public let id: UUID

    /// Base multiplier (minimum payout, usually 0)
    public let baseMultiplier: Double

    /// Maximum achievable multiplier
    public let maxMultiplier: Double

    /// The score at which max multiplier is achieved
    public let targetScore: Double

    /// How the curve scales between base and max
    public let curveType: CurveType

    public init(
        id: UUID,
        baseMultiplier: Double = 0,
        maxMultiplier: Double,
        targetScore: Double,
        curveType: CurveType = .linear
    ) {
        self.id = id
        self.baseMultiplier = baseMultiplier
        self.maxMultiplier = maxMultiplier
        self.targetScore = targetScore
        self.curveType = curveType
    }

    public func multiplier(for score: Double) -> Double {
        guard targetScore > 0 else { return baseMultiplier }
        let progress = min(max(score / targetScore, 0), 1)

        switch curveType {
        case .linear:
            return baseMultiplier + (maxMultiplier - baseMultiplier) * progress
        case .exponential(let exp):
            return baseMultiplier + (maxMultiplier - baseMultiplier) * pow(progress, exp)
        case .logarithmic:
            let logProgress = log(1 + progress * 9) / log(10)
            return baseMultiplier + (maxMultiplier - baseMultiplier) * logProgress
        }
    }
}

/// Curve type for continuous payout calculations.
public enum CurveType: Sendable, Codable, Equatable {
    case linear
    case exponential(Double)
    case logarithmic
}

// MARK: - Game Mode

public enum GameMode: String, Sendable, Codable {
    case singlePlayer = "single_player"
    case duel = "duel"
    case tournament = "tournament"
}

// MARK: - Session Player

/// A player in a game session.
/// Uses ZeroSettle backend user ID as the canonical identifier.
public struct SessionPlayer: Sendable, Equatable, Identifiable, Codable {
    /// ZeroSettle backend user UUID (fetched after auth)
    public let id: UUID

    /// Player's Solana wallet address
    public let wallet: SolanaAddress

    /// Player's stake status in this session
    public let stakeStatus: StakeStatus

    public init(id: UUID, wallet: SolanaAddress, stakeStatus: StakeStatus = .pending) {
        self.id = id
        self.wallet = wallet
        self.stakeStatus = stakeStatus
    }
}

public enum StakeStatus: String, Sendable, Codable {
    case pending = "pending"
    case staked = "staked"
    case refunded = "refunded"
}

// MARK: - Game Session

public struct GameSession: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let gameDefinitionId: UUID
    public let mode: GameMode
    public let entryFeeCents: Int
    public let maxPayoutMultiplier: Double
    public let players: [SessionPlayer]
    public let state: SessionState
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        gameDefinitionId: UUID,
        mode: GameMode,
        entryFeeCents: Int,
        maxPayoutMultiplier: Double,
        players: [SessionPlayer],
        state: SessionState,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.gameDefinitionId = gameDefinitionId
        self.mode = mode
        self.entryFeeCents = entryFeeCents
        self.maxPayoutMultiplier = maxPayoutMultiplier
        self.players = players
        self.state = state
        self.createdAt = createdAt
    }

    /// Total pot size in cents (all player stakes combined)
    public var totalPotCents: Int {
        entryFeeCents * players.count
    }

    /// Number of players who have staked
    public var stakedPlayerCount: Int {
        players.filter { $0.stakeStatus == .staked }.count
    }

    /// Whether all players have staked
    public var allPlayersStaked: Bool {
        players.allSatisfy { $0.stakeStatus == .staked }
    }
}

// MARK: - Session State

public enum SessionState: String, Sendable, Codable {
    case waitingForPlayers = "waiting_for_players"
    case pendingStakes = "pending_stakes"
    case escrowConfirmed = "escrow_confirmed"
    case inProgress = "in_progress"
    case pendingSettlement = "pending_settlement"
    case settled = "settled"
    case cancelled = "cancelled"
}

// MARK: - Settlement Result

public struct SettlementResult: Sendable, Codable {
    public let sessionId: UUID
    public let transactionSignature: String
    public let payouts: [PlayerPayout]
    public let platformFeeCents: Int

    public init(
        sessionId: UUID,
        transactionSignature: String,
        payouts: [PlayerPayout],
        platformFeeCents: Int
    ) {
        self.sessionId = sessionId
        self.transactionSignature = transactionSignature
        self.payouts = payouts
        self.platformFeeCents = platformFeeCents
    }
}

public struct PlayerPayout: Sendable, Codable {
    public let userId: UUID
    public let wallet: SolanaAddress
    public let amountCents: Int

    public init(userId: UUID, wallet: SolanaAddress, amountCents: Int) {
        self.userId = userId
        self.wallet = wallet
        self.amountCents = amountCents
    }
}

// MARK: - Game Result

public struct GameResult: Sendable, Codable {
    public let sessionId: UUID
    public let playerResults: [PlayerResult]

    public init(sessionId: UUID, playerResults: [PlayerResult]) {
        self.sessionId = sessionId
        self.playerResults = playerResults
    }
}

public struct PlayerResult: Sendable, Codable {
    public let userId: UUID
    public let finalMultiplier: Double

    public init(userId: UUID, finalMultiplier: Double) {
        self.userId = userId
        self.finalMultiplier = finalMultiplier
    }

    /// Multiplier in basis points (e.g., 2.5x = 250)
    public var multiplierBps: Int {
        Int(finalMultiplier * 100)
    }
}
