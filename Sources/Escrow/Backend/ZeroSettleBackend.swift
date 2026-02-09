//
//  ZeroSettleBackend.swift
//  ZeroSettleEscrow
//
//  Internal service for communicating with ZeroSettle's backend.
//

import Foundation
import ZeroSettleCore

// MARK: - Backend Errors

public enum ZeroSettleBackendError: Error, LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidResponse
    case serverError(statusCode: Int, message: String?)
    case networkError(Error)
    case decodingError(Error)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ZeroSettle backend is not configured"
        case .notAuthenticated:
            return "User is not authenticated. JWT token is missing."
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code, let message):
            if let message {
                return "Server error (\(code)): \(message)"
            }
            return "Server error: \(code)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }

    /// Convert an arbitrary error (typically `HTTPError`) into a structured `ZeroSettleBackendError`.
    /// If the error is already a `ZeroSettleBackendError`, it is returned unchanged.
    public static func from(_ error: Error) -> ZeroSettleBackendError {
        if let backendError = error as? ZeroSettleBackendError {
            return backendError
        }

        guard let httpError = error as? HTTPError else {
            return .networkError(error)
        }

        switch httpError {
        case .httpError(let statusCode, let body):
            var message: String?
            if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                message = json["error"] as? String ?? json["message"] as? String ?? json["detail"] as? String
            }
            return .serverError(statusCode: statusCode, message: message)

        case .decodingFailed(let decodingError):
            return .decodingError(decodingError)

        case .networkError(let underlyingError):
            return .networkError(underlyingError)

        case .invalidURL, .invalidResponse:
            return .invalidResponse
        }
    }
}

// MARK: - Backend Responses

struct PrivyLoginResponse: Decodable {
    let token: String
    let expiresAt: String
    let user: PrivyUserResponse

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case user
    }
}

struct PrivyUserResponse: Decodable {
    let id: Int  // Backend uses integer IDs for users
    let phoneNumber: String?
    let privyUserId: String
    let walletAddress: String?

    enum CodingKeys: String, CodingKey {
        case id
        case phoneNumber = "phone_number"
        case privyUserId = "privy_user_id"
        case walletAddress = "wallet_address"
    }
}

/// Response from Django's /sessions/start/ endpoint
struct SessionResponse: Decodable {
    let id: Int  // Database ID
    let gameSessionId: String  // UUID string for Solana
    let gameDefinitionId: Int
    let gameName: String
    let entryFee: Int
    let payoutFunctionId: Int
    let payoutExpression: String
    let startTime: String  // ISO8601 string
    let isOngoing: Bool
    let lowestScore: Double
    let highestScore: Double
    let scoringType: String
    let blockchainTransaction: BlockchainTransactionResponse?

    enum CodingKeys: String, CodingKey {
        case id
        case gameSessionId = "game_session_id"
        case gameDefinitionId = "game_definition_id"
        case gameName = "game_name"
        case entryFee = "entry_fee"
        case payoutFunctionId = "payout_function_id"
        case payoutExpression = "payout_expression"
        case startTime = "start_time"
        case isOngoing = "is_ongoing"
        case lowestScore = "lowest_score"
        case highestScore = "highest_score"
        case scoringType = "scoring_type"
        case blockchainTransaction = "blockchain_transaction"
    }
}

/// Blockchain transaction data returned when build_transaction=true
struct BlockchainTransactionResponse: Decodable {
    let partiallySignedTransaction: String  // Base64-encoded transaction
    let feePayer: String
    let instructionsCount: Int
    let gameSessionId: String

    enum CodingKeys: String, CodingKey {
        case partiallySignedTransaction = "partially_signed_transaction"
        case feePayer = "fee_payer"
        case instructionsCount = "instructions_count"
        case gameSessionId = "game_session_id"
    }
}

// Kept for future use when backend supports players list
struct SessionPlayerResponse: Decodable {
    let id: Int
    let wallet: String
    let stakeStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case wallet
        case stakeStatus = "stake_status"
    }
}

/// Response from Django's /sessions/<uuid>/confirm-escrow/ endpoint
struct ConfirmEscrowResponse: Decodable {
    let success: Bool
    let txSignature: String?
    let explorerUrl: String?
    let status: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case success
        case txSignature = "tx_signature"
        case explorerUrl = "explorer_url"
        case status
        case message
    }
}

/// Response from Django's /sessions/<uuid>/settle/ endpoint
struct SettleResponse: Decodable {
    let success: Bool
    let txSignature: String?
    let explorerUrl: String?
    let status: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case success
        case txSignature = "tx_signature"
        case explorerUrl = "explorer_url"
        case status
        case message
    }
}

struct SettlementResponse: Decodable {
    let sessionId: Int  // Django uses integer IDs
    let transactionSignature: String
    let payouts: [PayoutResponse]
    let platformFeeCents: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transactionSignature = "transaction_signature"
        case payouts
        case platformFeeCents = "platform_fee_cents"
    }
}

struct PayoutResponse: Decodable {
    let userId: Int  // Django uses integer IDs
    let wallet: String
    let amountCents: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case wallet
        case amountCents = "amount_cents"
    }
}

struct GameDefinitionResponse: Decodable {
    let id: Int  // Backend uses integer IDs
    let displayName: String
    let scoringType: String
    let lowestScore: Double
    let highestScore: Double
    let maxMultiplier: Double
    let scoreCurveType: String?
    let tenant: String?
    let payoutEntries: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case scoringType = "scoring_type"
        case lowestScore = "lowest_score"
        case highestScore = "highest_score"
        case maxMultiplier = "max_multiplier"
        case scoreCurveType = "score_curve_type"
        case tenant
        case payoutEntries = "payout_entries"
    }
}

struct PayoutTableResponse: Decodable {
    let id: UUID
    let type: String
    let entries: [PayoutEntryResponse]?
    let curve: PayoutCurveResponse?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case entries
        case curve
    }
}

struct PayoutEntryResponse: Decodable {
    let outcome: Int
    let multiplier: Double
}

struct PayoutCurveResponse: Decodable {
    let baseMultiplier: Double
    let maxMultiplier: Double
    let targetScore: Double
    let curveType: String

    enum CodingKeys: String, CodingKey {
        case baseMultiplier = "base_multiplier"
        case maxMultiplier = "max_multiplier"
        case targetScore = "target_score"
        case curveType = "curve_type"
    }
}

// MARK: - JWT Token Provider

/// Protocol for providing JWT tokens for API authentication.
/// Privy's SDK provides JWT tokens after authentication.
public protocol JWTTokenProvider: Sendable {
    /// Returns the current JWT token, or nil if not authenticated.
    func getAccessToken() async -> String?
}

// MARK: - ZeroSettle Backend

/// Internal service for communicating with ZeroSettle's backend.
/// After Privy auth, calls privy-login to get a Django session token.
/// All subsequent API calls use this session token (not the Privy JWT).
internal final class ZeroSettleBackend: @unchecked Sendable {

    private let baseURL: URL
    private let httpClient: HTTPClient
    private let partnerAppId: Int
    private let tokenProvider: JWTTokenProvider

    /// Django session token from privy-login (used for all authenticated requests)
    private(set) var sessionToken: String?

    init(
        baseURL: URL,
        partnerAppId: Int,
        tokenProvider: JWTTokenProvider,
        httpClient: HTTPClient = .shared
    ) {
        self.baseURL = baseURL
        self.partnerAppId = partnerAppId
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
    }

    // MARK: - User

    /// Register or fetch user from backend after Privy auth.
    /// The JWT token is verified server-side to extract Privy user ID.
    /// - Parameter walletAddress: The user's Solana wallet address
    /// - Returns: The ZeroSettle user UUID (derived from backend's integer ID)
    func registerUser(walletAddress: SolanaAddress) async throws -> UUID {
        let url = baseURL.appendingPathComponent("auth/privy-login/")

        // Get the access token to send in the body (backend expects it there)
        guard let accessToken = await tokenProvider.getAccessToken() else {
            throw ZeroSettleBackendError.notAuthenticated
        }

        struct RegisterRequest: Encodable {
            let privyAccessToken: String
            let walletAddress: String

            enum CodingKeys: String, CodingKey {
                case privyAccessToken = "privy_access_token"
                case walletAddress = "wallet_address"
            }
        }

        let request = RegisterRequest(
            privyAccessToken: accessToken,
            walletAddress: walletAddress.base58
        )

        let response: PrivyLoginResponse = try await httpClient.post(
            url,
            body: request,
            headers: ["Content-Type": "application/json"],
            responseType: PrivyLoginResponse.self
        )

        // Store the Django session token for subsequent authenticated requests
        self.sessionToken = response.token
        Logger.debug("Django session token stored (length: \(response.token.count))", category: .escrow)

        // Convert integer user ID to UUID format for framework compatibility
        // Format: 00000000-0000-0000-0000-{12-digit padded ID}
        let paddedId = String(format: "%012d", response.user.id)
        let uuidString = "00000000-0000-0000-0000-\(paddedId)"
        guard let userId = UUID(uuidString: uuidString) else {
            throw ZeroSettleBackendError.invalidResponse
        }

        Logger.info("User registered: \(userId) (backend id: \(response.user.id))", category: .escrow)
        return userId
    }

    // MARK: - Game Configuration

    /// Get game definition by name, including payout table.
    /// This is a public endpoint - no auth required.
    func getGameDefinition(name: String) async throws -> GameDefinition {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let url = baseURL.appendingPathComponent("games/by-name/\(encodedName)/")

        // Public endpoint - no auth headers needed
        let response: GameDefinitionResponse = try await httpClient.get(
            url,
            headers: ["Content-Type": "application/json"],
            responseType: GameDefinitionResponse.self
        )

        Logger.info("Game definition loaded: \(response.displayName)", category: .escrow)
        return mapGameDefinition(response)
    }

    // MARK: - Sessions

    /// Result of starting a session, includes both session and optional stake transaction
    struct StartSessionResult {
        let session: GameSession
        let playerStakeTransaction: String?  // Base64-encoded partially-signed transaction
    }

    /// Start a new game session.
    /// - Parameters:
    ///   - userId: The user's UUID (converted to integer for Django)
    ///   - walletAddress: The user's Solana wallet address (stored as player_wallet for confirm-escrow)
    ///   - gameDefinitionId: The game definition UUID
    ///   - mode: Game mode (single player, duel, etc.)
    ///   - entryFeeCents: Entry fee in cents
    ///   - maxPayoutMultiplier: Maximum payout multiplier
    /// - Returns: Session and partially-signed player stake transaction (if entry fee > 0)
    func startSession(
        userId: UUID,
        walletAddress: SolanaAddress,
        gameDefinitionId: UUID,
        mode: GameMode,
        entryFeeCents: Int,
        maxPayoutMultiplier: Double
    ) async throws -> StartSessionResult {
        let url = baseURL.appendingPathComponent("sessions/start/")

        // Convert UUIDs back to integers for Django backend
        // Our UUID format: 00000000-0000-0000-0000-{12-digit padded ID}
        let userIdInt = extractIntegerId(from: userId)
        let gameDefIdInt = extractIntegerId(from: gameDefinitionId)

        struct StartSessionRequest: Encodable {
            let userId: Int
            let gameDefinitionId: Int
            let mode: String
            let entryFee: Int  // USDC base units (6 decimals) - used directly in blockchain tx
            let maxPayoutMultiplier: Double
            let userPubkey: String  // Player's wallet address - stored as player_wallet
            let buildTransaction: Bool  // Request blockchain transaction

            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case gameDefinitionId = "game_definition_id"
                case mode
                case entryFee = "entry_fee"
                case maxPayoutMultiplier = "max_payout_multiplier"
                case userPubkey = "user_pubkey"
                case buildTransaction = "build_transaction"
            }
        }

        // Request blockchain transaction if there's an entry fee
        let shouldBuildTransaction = entryFeeCents > 0

        // Convert cents to USDC base units (6 decimals)
        // 1 USDC = 1,000,000 base units = 100 cents
        // So 1 cent = 10,000 base units
        let entryFeeBaseUnits = entryFeeCents * 10_000

        Logger.debug("Entry fee conversion: \(entryFeeCents) cents → \(entryFeeBaseUnits) base units ($\(String(format: "%.2f", Double(entryFeeCents) / 100.0)))", category: .escrow)

        let request = StartSessionRequest(
            userId: userIdInt,
            gameDefinitionId: gameDefIdInt,
            mode: mode.rawValue,
            entryFee: entryFeeBaseUnits,
            maxPayoutMultiplier: maxPayoutMultiplier,
            userPubkey: walletAddress.base58,
            buildTransaction: shouldBuildTransaction
        )

        let response: SessionResponse = try await httpClient.post(
            url,
            body: request,
            headers: try authHeaders(),
            responseType: SessionResponse.self
        )

        Logger.info("Session created: \(response.id)", category: .escrow)

        let session = mapSession(response)
        let playerStakeTx = response.blockchainTransaction?.partiallySignedTransaction

        if let tx = playerStakeTx {
            Logger.info("Player stake transaction received (length: \(tx.count))", category: .escrow)
        } else if shouldBuildTransaction {
            Logger.debug("Expected blockchain transaction but none received", category: .escrow)
        }

        return StartSessionResult(session: session, playerStakeTransaction: playerStakeTx)
    }

    /// Confirm escrow for a session (player has staked).
    /// Django expects the game_session_id UUID in the URL path.
    func confirmEscrow(sessionId: UUID, userId: UUID) async throws {
        // sessionId is already the game_session_id UUID from mapSession
        let url = baseURL.appendingPathComponent("sessions/\(sessionId.uuidString.lowercased())/confirm-escrow/")

        struct ConfirmRequest: Encodable {
            let platformRateBps: Int

            enum CodingKeys: String, CodingKey {
                case platformRateBps = "platform_rate_bps"
            }
        }

        // Django's confirm-escrow only needs platform_rate_bps (optional, defaults to 500 = 5%)
        let request = ConfirmRequest(platformRateBps: 500)

        let response: ConfirmEscrowResponse = try await httpClient.post(
            url,
            body: request,
            headers: try authHeaders(),
            responseType: ConfirmEscrowResponse.self
        )

        if response.success {
            Logger.info("Escrow confirmed for session: \(sessionId), tx: \(response.txSignature ?? "N/A")", category: .escrow)
        } else {
            throw ZeroSettleBackendError.serverError(statusCode: 500, message: response.message ?? "Escrow confirmation failed")
        }
    }

    /// Settle a game session and distribute funds.
    /// Django expects the game_session_id UUID in the URL path.
    ///
    /// - Note: This triggers the on-chain settlement transaction.
    ///   The game result should have been submitted first via submit_result.
    func settleSession(sessionId: UUID) async throws -> SettleResponse {
        // sessionId should be the game_session_id UUID
        let url = baseURL.appendingPathComponent("sessions/\(sessionId.uuidString.lowercased())/settle/")

        struct SettleRequest: Encodable {
            let platformRateBps: Int

            enum CodingKeys: String, CodingKey {
                case platformRateBps = "platform_rate_bps"
            }
        }

        let request = SettleRequest(platformRateBps: 500)

        let response: SettleResponse = try await httpClient.post(
            url,
            body: request,
            headers: try authHeaders(),
            responseType: SettleResponse.self
        )

        if response.success {
            Logger.info("Session settled: \(sessionId), tx: \(response.txSignature ?? "N/A")", category: .escrow)
        }

        return response
    }

    // MARK: - Helpers

    private func authHeaders() throws -> [String: String] {
        guard let token = sessionToken else {
            Logger.error("No Django session token - user may not be registered", category: .network)
            throw ZeroSettleBackendError.notAuthenticated
        }

        Logger.debug("Using Django session token (length: \(token.count))", category: .network)
        return [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(token)"
        ]
    }

    /// Extract integer ID from our UUID format.
    /// Our format: 00000000-0000-0000-0000-{12-digit padded ID}
    /// Example: 00000000-0000-0000-0000-000000000001 -> 1
    private func extractIntegerId(from uuid: UUID) -> Int {
        let uuidString = uuid.uuidString
        // Get last 12 characters (the padded integer ID)
        let suffix = String(uuidString.suffix(12))
        return Int(suffix) ?? 0
    }

    /// Convert integer ID to our UUID format.
    /// Format: 00000000-0000-0000-0000-{12-digit padded ID}
    /// Example: 1 -> 00000000-0000-0000-0000-000000000001
    private func makeUUID(from intId: Int) -> UUID {
        let paddedId = String(format: "%012d", intId)
        let uuidString = "00000000-0000-0000-0000-\(paddedId)"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private func mapSession(_ response: SessionResponse) -> GameSession {
        // Parse start time from ISO8601 string
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdAt = dateFormatter.date(from: response.startTime) ?? Date()

        // Django doesn't return players list - create empty for now
        // Players will be added when they stake
        let players: [SessionPlayer] = []

        // IMPORTANT: Use game_session_id (real UUID) not id (integer)
        // Django expects game_session_id in URL paths for confirm-escrow, settle, etc.
        let sessionUUID = UUID(uuidString: response.gameSessionId) ?? UUID()

        // Note: Django returns entry_fee in USDC base units (what we send)
        // Convert back to cents for the session model
        // 1 cent = 10,000 base units, so divide by 10,000
        let entryFeeCents = response.entryFee / 10_000

        return GameSession(
            id: sessionUUID,  // Use the real UUID from game_session_id
            gameDefinitionId: makeUUID(from: response.gameDefinitionId),
            mode: .singlePlayer,  // Django doesn't return mode, default to single player
            entryFeeCents: entryFeeCents,
            maxPayoutMultiplier: 10.0,  // Django doesn't return this in session response
            players: players,
            state: response.isOngoing ? .inProgress : .waitingForPlayers,
            createdAt: createdAt
        )
    }

    private func mapSettlement(_ response: SettlementResponse) -> SettlementResult {
        let payouts = response.payouts.map { payout in
            PlayerPayout(
                userId: makeUUID(from: payout.userId),
                wallet: SolanaAddress(trusted: payout.wallet),
                amountCents: payout.amountCents
            )
        }

        return SettlementResult(
            sessionId: makeUUID(from: response.sessionId),
            transactionSignature: response.transactionSignature,
            payouts: payouts,
            platformFeeCents: response.platformFeeCents
        )
    }

    private func mapGameDefinition(_ response: GameDefinitionResponse) -> GameDefinition {
        // Convert integer ID to UUID format for framework compatibility
        let paddedId = String(format: "%012d", response.id)
        let uuidString = "00000000-0000-0000-0000-\(paddedId)"
        let gameId = UUID(uuidString: uuidString) ?? UUID()

        let payoutTable: PayoutTable

        // Build payout table based on scoring type
        if response.scoringType == "discrete" {
            var entries: [DiscretePayoutEntry] = []
            let scoreRange = Int(response.lowestScore)...Int(response.highestScore)

            // Use actual payout entries from backend if available
            if let payoutEntries = response.payoutEntries {
                for score in scoreRange {
                    let multiplier = payoutEntries[String(score)] ?? 0.0
                    entries.append(DiscretePayoutEntry(outcome: score, multiplier: multiplier))
                }
            } else {
                // Fallback: calculate multipliers from maxMultiplier
                for score in scoreRange {
                    let multiplier: Double
                    if score == Int(response.highestScore) {
                        multiplier = 0.0
                    } else {
                        let normalized = Double(score - Int(response.lowestScore)) / Double(Int(response.highestScore) - Int(response.lowestScore) - 1)
                        multiplier = response.maxMultiplier * (1.0 - normalized)
                    }
                    entries.append(DiscretePayoutEntry(outcome: score, multiplier: multiplier))
                }
            }

            payoutTable = .discrete(DiscretePayoutTable(
                id: gameId,
                entries: entries
            ))
        } else {
            // Continuous scoring (like 2048)
            let curveType: CurveType
            switch response.scoreCurveType {
            case "exponential":
                curveType = .exponential(2.0)
            case "logarithmic":
                curveType = .logarithmic
            case "inverse_power":
                curveType = .exponential(0.5) // Inverse power approximation
            default:
                curveType = .linear
            }

            payoutTable = .continuous(ContinuousPayoutTable(
                id: gameId,
                baseMultiplier: 0.0,
                maxMultiplier: response.maxMultiplier,
                targetScore: response.highestScore,
                curveType: curveType
            ))
        }

        return GameDefinition(
            id: gameId,
            name: response.displayName.lowercased(),
            displayName: response.displayName,
            description: nil,
            payoutTable: payoutTable
        )
    }
}
