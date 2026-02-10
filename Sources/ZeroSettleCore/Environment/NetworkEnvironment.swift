//
//  NetworkEnvironment.swift
//  ZeroSettleCore
//
//  Network environment configuration for production, development, and local.
//

import Foundation

public enum NetworkEnvironment: String, Codable, Sendable, CaseIterable {
    case production
    case development

    public var displayName: String {
        switch self {
        case .production: return "Production"
        case .development: return "Development"
        }
    }

    // MARK: - ZeroSettle Backend

    /// ZeroSettle backend API URL
    public var backendURL: URL {
        switch self {
        case .production:
            return URL(string: "https://api.zerosettle.io/v1")!
        case .development:
            return URL(string: "https://api.zerosettle.io/v1")!
        }
    }

    // MARK: - Blockchain RPC
    // Note: These are public for internal framework module access.
    // Client apps only import ZeroSettleEscrow which doesn't expose these.

    public var solanaRpcURL: URL {
        switch self {
        case .production:
            return URL(string: "https://api.mainnet-beta.solana.com")!
        case .development:
            return URL(string: "https://api.devnet.solana.com")!
        }
    }

    public var solanaWebSocketURL: URL {
        switch self {
        case .production:
            return URL(string: "wss://api.mainnet-beta.solana.com")!
        case .development:
            return URL(string: "wss://api.devnet.solana.com")!
        }
    }

    /// Solana explorer URL for viewing transactions
    public func explorerURL(forTransaction signature: String) -> URL {
        switch self {
        case .production:
            return URL(string: "https://explorer.solana.com/tx/\(signature)")!
        case .development:
            return URL(string: "https://explorer.solana.com/tx/\(signature)?cluster=devnet")!
        }
    }

    // MARK: - Stablecoin Configuration

    /// Default USDC mint for the environment.
    public var defaultUSDCMint: String {
        switch self {
        case .production:
            return "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"  // Mainnet USDC
        case .development:
            return "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"  // Devnet USDC
        }
    }
}

// MARK: - Custom USDC Configuration

/// Configuration for custom USDC mint override.
public struct USDCConfig: Sendable {
    public let usdcMint: String?

    public init(usdcMint: String? = nil) {
        self.usdcMint = usdcMint
    }

    /// Resolve USDC mint address with fallback to environment default.
    public func resolvedMint(for environment: NetworkEnvironment) -> String {
        return usdcMint ?? environment.defaultUSDCMint
    }
}
