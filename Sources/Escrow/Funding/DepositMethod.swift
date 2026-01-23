//
//  DepositMethod.swift
//  ZeroSettleEscrow
//
//  Deposit method types and configuration for funding escrow accounts.
//

import Foundation

// MARK: - Deposit Method

/// Available methods for depositing funds into a ZeroSettle escrow account.
public enum DepositMethod: String, CaseIterable, Sendable {
    case applePay = "Apple Pay"
    case stripe = "Credit/Debit Card"
    case phantom = "Phantom"
    case metamask = "MetaMask"
    case coinbase = "Coinbase"

    /// Display name for the deposit method
    public var displayName: String {
        rawValue
    }

    /// SF Symbol name for the deposit method icon
    public var systemIconName: String {
        switch self {
        case .applePay:
            return "applelogo"
        case .stripe:
            return "creditcard.fill"
        case .phantom:
            return "wallet.pass.fill"
        case .metamask:
            return "hexagon.fill"
        case .coinbase:
            return "bitcoinsign.circle.fill"
        }
    }

    /// Asset name for custom icon (if available in framework bundle)
    public var assetIconName: String? {
        switch self {
        case .phantom:
            return "PhantomIcon"
        case .coinbase:
            return "CoinbaseIcon"
        default:
            return nil
        }
    }

    /// The blockchain network this deposit method uses
    public var blockchain: DepositBlockchain {
        switch self {
        case .applePay, .stripe, .coinbase:
            return .base
        case .phantom:
            return .solana
        case .metamask:
            return .ethereum
        }
    }

    /// Whether this method requires an external wallet connection
    public var requiresWalletConnection: Bool {
        switch self {
        case .applePay, .stripe:
            return false
        case .phantom, .metamask, .coinbase:
            return true
        }
    }

    /// Brief description of the deposit method
    public var description: String {
        switch self {
        case .applePay:
            return "Pay with Apple Pay"
        case .stripe:
            return "Pay with credit or debit card"
        case .phantom:
            return "Transfer USDC from Phantom wallet"
        case .metamask:
            return "Transfer USDC from MetaMask wallet"
        case .coinbase:
            return "Transfer USDC from Coinbase Wallet on Base"
        }
    }
}

// MARK: - Deposit Blockchain

/// Blockchain networks supported for deposits.
public enum DepositBlockchain: String, Sendable {
    case solana
    case ethereum
    case base
    case polygon
    case arbitrum
    case optimism

    public var displayName: String {
        switch self {
        case .solana: return "Solana"
        case .ethereum: return "Ethereum"
        case .base: return "Base"
        case .polygon: return "Polygon"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        }
    }

    /// Chain ID for EVM-compatible networks
    public var evmChainId: String? {
        switch self {
        case .ethereum: return "0x1"
        case .base: return "0x2105"
        case .polygon: return "0x89"
        case .arbitrum: return "0xa4b1"
        case .optimism: return "0xa"
        case .solana: return nil
        }
    }
}

// MARK: - Deposit Result

/// Result of a deposit operation.
public struct DepositResult: Sendable, Equatable {
    /// The deposit method used
    public let method: DepositMethod

    /// Amount deposited in cents
    public let amountCents: Int

    /// Transaction signature/hash (if available)
    public let transactionId: String?

    /// Whether the deposit was successful
    public let success: Bool

    /// Error message if deposit failed
    public let errorMessage: String?

    public init(
        method: DepositMethod,
        amountCents: Int,
        transactionId: String? = nil,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.method = method
        self.amountCents = amountCents
        self.transactionId = transactionId
        self.success = success
        self.errorMessage = errorMessage
    }
}

// MARK: - Deposit Configuration

/// Configuration for a deposit operation.
public struct DepositConfiguration: Sendable {
    /// Destination wallet addresses for each blockchain
    public let walletAddresses: [DepositBlockchain: String]

    /// Callback URL for payment redirects
    public let callbackURL: URL?

    /// App URL scheme for deep link returns
    public let appScheme: String

    public init(
        walletAddresses: [DepositBlockchain: String],
        callbackURL: URL? = nil,
        appScheme: String = "wordplay"
    ) {
        self.walletAddresses = walletAddresses
        self.callbackURL = callbackURL
        self.appScheme = appScheme
    }

    /// Get wallet address for a specific blockchain
    public func walletAddress(for blockchain: DepositBlockchain) -> String? {
        walletAddresses[blockchain]
    }
}
