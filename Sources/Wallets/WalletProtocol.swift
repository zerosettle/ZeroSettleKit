//
//  WalletProtocol.swift
//  ZeroSettleWallets
//
//  Common protocol for external Solana wallet integrations.
//

import Foundation
import ZeroSettleCore

// MARK: - Wallet Types

public enum WalletType: String, Sendable {
    case phantom = "phantom"
    case metamask = "metamask"
    case coinbase = "coinbase"
    case privyEmbedded = "privy_embedded"
}

// MARK: - Wallet Info

public struct WalletInfo: Sendable, Equatable {
    public let address: String
    public let walletType: WalletType
    public let isNew: Bool

    public init(address: String, walletType: WalletType, isNew: Bool = false) {
        self.address = address
        self.walletType = walletType
        self.isNew = isNew
    }

    public var formattedAddress: String {
        address.formatAsAddress()
    }
}

// MARK: - Wallet Protocol

/// Protocol for external Solana wallet integrations (Phantom, MetaMask, Coinbase).
@MainActor
public protocol WalletManager: ObservableObject {
    /// Whether the wallet app is connected
    var isConnected: Bool { get }

    /// The connected Solana wallet address (if connected)
    var walletAddress: String? { get }

    /// The wallet type
    var walletType: WalletType { get }

    /// Connect to the wallet app
    func connect() async throws

    /// Disconnect from the wallet
    func disconnect() async

    /// Sign a Solana message
    /// - Parameter messageBase64: Base64-encoded message bytes
    /// - Returns: Base58-encoded signature
    func signMessage(_ messageBase64: String) async throws -> String

    /// Sign a Solana transaction
    /// - Parameter transactionBase64: Base64-encoded transaction
    /// - Returns: Base64-encoded signed transaction
    func signTransaction(_ transactionBase64: String) async throws -> String

    /// Handle a deeplink callback from the wallet app
    func handleDeeplink(_ url: URL) -> Bool
}

// MARK: - Wallet Errors

public enum WalletError: Error, LocalizedError {
    case notInstalled
    case connectionFailed(Error?)
    case connectionRejected
    case signingFailed(Error?)
    case signingRejected
    case invalidResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Wallet app is not installed"
        case .connectionFailed(let error):
            if let error {
                return "Connection failed: \(error.localizedDescription)"
            }
            return "Connection failed"
        case .connectionRejected:
            return "Connection was rejected by user"
        case .signingFailed(let error):
            if let error {
                return "Signing failed: \(error.localizedDescription)"
            }
            return "Signing failed"
        case .signingRejected:
            return "Signing was rejected by user"
        case .invalidResponse:
            return "Invalid response from wallet"
        case .timeout:
            return "Wallet operation timed out"
        }
    }
}
