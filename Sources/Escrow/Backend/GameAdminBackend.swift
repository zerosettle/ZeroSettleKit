//
//  GameAdminBackend.swift
//  ZeroSettleEscrow
//
//  Protocol and default implementation for client's game server integration.
//

import Foundation
import ZeroSettleCore

// MARK: - Game Admin Backend Protocol

/// Protocol for the game admin's backend (infrastructure CLIENT controls).
/// Implement this to integrate your game server with ZeroSettle.
public protocol GameAdminBackend: Sendable {

    /// Called when player stakes - your backend should stake the game admin liability.
    /// - Parameters:
    ///   - sessionId: The game session UUID
    ///   - gameDefinitionId: The game definition integer ID
    ///   - entryFeeLamports: The player's entry fee in USDC base units (6 decimals)
    ///   - maxPayoutMultiplier: Maximum payout multiplier for this session
    ///   - playerWalletAddress: The player's Solana wallet address (base58)
    /// - Returns: The transaction signature of the game admin stake (for confirmation tracking)
    func onPlayerStaked(
        sessionId: UUID,
        gameDefinitionId: Int,
        entryFeeLamports: Int,
        maxPayoutMultiplier: Double,
        playerWalletAddress: String
    ) async throws -> String

    /// Called when game ends - submits the result on-chain.
    /// Must be called before settlement to set the session status correctly.
    /// - Parameters:
    ///   - sessionId: The game session UUID
    ///   - finalMultiplierBps: The final payout multiplier in basis points (e.g., 250 = 2.5x)
    ///   - playerWalletAddress: The player's Solana wallet address (base58)
    func submitResult(
        sessionId: UUID,
        finalMultiplierBps: Int,
        playerWalletAddress: String
    ) async throws

    /// Called to get the final game result for settlement.
    /// - Parameter sessionId: The game session UUID
    /// - Returns: The game result with player multipliers
    func getGameResult(sessionId: UUID) async throws -> GameResult
}

// MARK: - REST Implementation

/// Default REST-based implementation of GameAdminBackend.
/// Configure with your game server's base URL.
public final class RestGameAdminBackend: GameAdminBackend, @unchecked Sendable {

    private let baseURL: URL
    private let httpClient: HTTPClient
    private let authTokenProvider: @Sendable () -> String?

    public init(
        baseURL: URL,
        httpClient: HTTPClient = .shared,
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.authTokenProvider = authTokenProvider
    }

    public func onPlayerStaked(
        sessionId: UUID,
        gameDefinitionId: Int,
        entryFeeLamports: Int,
        maxPayoutMultiplier: Double,
        playerWalletAddress: String
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("stake")

        var headers: [String: String] = ["Content-Type": "application/json"]
        if let token = authTokenProvider() {
            headers["Authorization"] = "Bearer \(token)"
        }

        struct StakeRequest: Encodable {
            let gameSessionId: UUID
            let gameDefinitionId: Int
            let entryFee: Int
            let maxPayoutMultiplier: Double
            let userPubkey: String

            enum CodingKeys: String, CodingKey {
                case gameSessionId = "game_session_id"
                case gameDefinitionId = "game_definition_id"
                case entryFee = "entry_fee"
                case maxPayoutMultiplier = "max_payout_multiplier"
                case userPubkey = "user_pubkey"
            }
        }

        struct StakeResponse: Decodable {
            let success: Bool
            let transactionSignature: String?

            enum CodingKeys: String, CodingKey {
                case success
                case transactionSignature = "transaction_signature"
            }
        }

        let request = StakeRequest(
            gameSessionId: sessionId,
            gameDefinitionId: gameDefinitionId,
            entryFee: entryFeeLamports,
            maxPayoutMultiplier: maxPayoutMultiplier,
            userPubkey: playerWalletAddress
        )
        let response: StakeResponse = try await httpClient.post(url, body: request, headers: headers, responseType: StakeResponse.self)

        if let txSignature = response.transactionSignature {
            Logger.info("Game admin stake submitted: \(txSignature.prefix(16))...", category: .escrow)
            return txSignature
        } else {
            Logger.debug("Game admin backend using legacy mode", category: .escrow)
            return ""
        }
    }

    public func submitResult(
        sessionId: UUID,
        finalMultiplierBps: Int,
        playerWalletAddress: String
    ) async throws {
        let url = baseURL.appendingPathComponent("submit-result")

        var headers: [String: String] = ["Content-Type": "application/json"]
        if let token = authTokenProvider() {
            headers["Authorization"] = "Bearer \(token)"
        }

        struct SubmitResultRequest: Encodable {
            let gameSessionId: UUID
            let finalMultiplier: Int
            let userPubkey: String

            enum CodingKeys: String, CodingKey {
                case gameSessionId = "game_session_id"
                case finalMultiplier = "final_multiplier"
                case userPubkey = "user_pubkey"
            }
        }

        struct SubmitResultResponse: Decodable {
            let success: Bool
        }

        let request = SubmitResultRequest(
            gameSessionId: sessionId,
            finalMultiplier: finalMultiplierBps,
            userPubkey: playerWalletAddress
        )
        let _: SubmitResultResponse = try await httpClient.post(url, body: request, headers: headers, responseType: SubmitResultResponse.self)

        Logger.info("Game result submitted for session: \(sessionId.uuidString), multiplier: \(finalMultiplierBps)bps", category: .escrow)
    }

    public func getGameResult(sessionId: UUID) async throws -> GameResult {
        let url = baseURL.appendingPathComponent("result/\(sessionId.uuidString)")

        var headers: [String: String] = [:]
        if let token = authTokenProvider() {
            headers["Authorization"] = "Bearer \(token)"
        }

        struct PlayerResultResponse: Decodable {
            let userId: UUID
            let finalMultiplier: Double

            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case finalMultiplier = "final_multiplier"
            }
        }

        struct ResultResponse: Decodable {
            let sessionId: UUID
            let playerResults: [PlayerResultResponse]

            enum CodingKeys: String, CodingKey {
                case sessionId = "session_id"
                case playerResults = "player_results"
            }
        }

        let response: ResultResponse = try await httpClient.get(url, headers: headers, responseType: ResultResponse.self)

        let playerResults = response.playerResults.map { result in
            PlayerResult(userId: result.userId, finalMultiplier: result.finalMultiplier)
        }

        return GameResult(
            sessionId: response.sessionId,
            playerResults: playerResults
        )
    }
}
