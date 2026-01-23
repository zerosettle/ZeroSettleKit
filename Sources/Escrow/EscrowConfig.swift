//
//  EscrowConfig.swift
//  ZeroSettleEscrow
//
//  Configuration for the ZeroSettle Escrow SDK.
//

import Foundation
import ZeroSettleCore

// MARK: - Escrow Configuration

public struct EscrowConfig: Sendable {
    /// Privy app ID for authentication
    public let privyAppId: String

    /// Privy client ID
    public let privyClientId: String

    /// Your partner app ID from ZeroSettle dashboard
    public let partnerAppId: Int

    /// Network environment for backend API (production, development, or local)
    public let environment: NetworkEnvironment

    /// Blockchain environment (defaults to same as backend, but can be overridden)
    /// Use this to hit mainnet blockchain while using local backend
    public let blockchainEnvironment: NetworkEnvironment

    /// Custom token mint for local development (optional)
    public let localTokenMint: SolanaAddress?

    /// Your game admin backend URL (optional - for GameAdminBackend)
    public let gameBackendURL: URL?

    public init(
        privyAppId: String,
        privyClientId: String,
        partnerAppId: Int,
        environment: NetworkEnvironment = .production,
        blockchainEnvironment: NetworkEnvironment? = nil,
        localTokenMint: SolanaAddress? = nil,
        gameBackendURL: URL? = nil
    ) {
        self.privyAppId = privyAppId
        self.privyClientId = privyClientId
        self.partnerAppId = partnerAppId
        self.environment = environment
        self.blockchainEnvironment = blockchainEnvironment ?? environment
        self.localTokenMint = localTokenMint
        self.gameBackendURL = gameBackendURL
    }

    // MARK: - Internal

    /// Backend URL derived from environment
    internal var backendURL: URL {
        environment.backendURL
    }

    /// Solana RPC URL (uses blockchainEnvironment)
    internal var solanaRpcURL: URL {
        blockchainEnvironment.solanaRpcURL
    }

    /// Solana WebSocket URL for real-time subscriptions (uses blockchainEnvironment)
    internal var solanaWebSocketURL: URL {
        blockchainEnvironment.solanaWebSocketURL
    }

    /// Resolved token mint address (uses blockchainEnvironment)
    /// For `.local` environment, `localTokenMint` must be provided.
    internal var tokenMint: SolanaAddress {
        if let customMint = localTokenMint {
            return customMint
        }
        guard let defaultMint = blockchainEnvironment.defaultUSDCMint else {
            fatalError("localTokenMint must be provided when using .local blockchain environment")
        }
        return SolanaAddress(trusted: defaultMint)
    }
}
