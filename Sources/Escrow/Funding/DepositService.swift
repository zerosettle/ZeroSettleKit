//
//  DepositService.swift
//  ZeroSettleEscrow
//
//  Service for handling deposits via various payment methods.
//  Apps implement deposit handlers for each method they support.
//

import Foundation

// MARK: - Deposit Handler Protocol

/// Protocol for handling deposits via a specific method.
/// Apps implement this protocol for each deposit method they support.
public protocol DepositHandler: AnyObject {
    /// The deposit method this handler supports
    var method: DepositMethod { get }

    /// Whether this deposit method is currently available
    var isAvailable: Bool { get }

    /// Whether a wallet connection is required and established
    var isConnected: Bool { get }

    /// The connected wallet address (if applicable)
    var connectedAddress: String? { get }

    /// Connect the wallet (for wallet-based methods)
    func connect() async throws

    /// Disconnect the wallet
    func disconnect()

    /// Initiate a deposit
    /// - Parameters:
    ///   - amountCents: Amount to deposit in cents
    ///   - destinationAddress: Destination wallet address
    /// - Returns: Transaction ID if available
    func deposit(amountCents: Int, destinationAddress: String) async throws -> String?
}

// MARK: - Deposit Service Delegate

/// Delegate for receiving deposit service events.
public protocol DepositServiceDelegate: AnyObject {
    /// Called when a deposit is initiated
    func depositServiceDidInitiate(method: DepositMethod, amountCents: Int)

    /// Called when a deposit completes successfully
    func depositServiceDidComplete(result: DepositResult)

    /// Called when a deposit fails
    func depositServiceDidFail(method: DepositMethod, error: Error)
}

// MARK: - Default Delegate Implementation

public extension DepositServiceDelegate {
    func depositServiceDidInitiate(method: DepositMethod, amountCents: Int) {}
    func depositServiceDidComplete(result: DepositResult) {}
    func depositServiceDidFail(method: DepositMethod, error: Error) {}
}

// MARK: - Deposit Service Errors

public enum DepositServiceError: Error, LocalizedError {
    case notConfigured
    case handlerNotRegistered(DepositMethod)
    case walletNotConnected(DepositMethod)
    case invalidDestinationAddress
    case missingWalletAddress(DepositBlockchain)
    case depositFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Deposit service is not configured"
        case .handlerNotRegistered(let method):
            return "No handler registered for \(method.displayName)"
        case .walletNotConnected(let method):
            return "\(method.displayName) wallet is not connected"
        case .invalidDestinationAddress:
            return "Invalid destination wallet address"
        case .missingWalletAddress(let blockchain):
            return "No wallet address configured for \(blockchain.displayName)"
        case .depositFailed(let message):
            return "Deposit failed: \(message)"
        }
    }
}

// MARK: - Deposit Service

/// Service for coordinating deposits into ZeroSettle escrow accounts.
///
/// Apps register handlers for each deposit method they support:
/// ```swift
/// let service = DepositService.shared
/// service.configure(DepositConfiguration(
///     walletAddresses: [.solana: "...", .base: "..."]
/// ))
///
/// // Register handlers
/// service.registerHandler(PhantomDepositHandler())
/// service.registerHandler(StripeDepositHandler())
///
/// // Initiate deposit
/// try await service.deposit(method: .phantom, amountCents: 500)
/// ```
@MainActor
public final class DepositService: ObservableObject {

    // MARK: - Singleton

    public static let shared = DepositService()

    // MARK: - Published State

    /// Whether a deposit is currently in progress
    @Published public private(set) var isProcessing: Bool = false

    /// The method currently being used for deposit
    @Published public private(set) var currentMethod: DepositMethod?

    /// Current error message (if any)
    @Published public private(set) var errorMessage: String?

    /// Last successful deposit result
    @Published public private(set) var lastResult: DepositResult?

    // MARK: - Configuration

    private var configuration: DepositConfiguration?
    private var handlers: [DepositMethod: DepositHandler] = [:]

    /// Delegate for receiving deposit events
    public weak var delegate: DepositServiceDelegate?

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Configure the deposit service with wallet addresses.
    public func configure(_ config: DepositConfiguration) {
        self.configuration = config
    }

    /// Get the current configuration.
    public var currentConfiguration: DepositConfiguration? {
        configuration
    }

    // MARK: - Handler Registration

    /// Register a deposit handler for a specific method.
    public func registerHandler(_ handler: DepositHandler) {
        handlers[handler.method] = handler
    }

    /// Unregister a deposit handler.
    public func unregisterHandler(for method: DepositMethod) {
        handlers.removeValue(forKey: method)
    }

    /// Get the registered handler for a method.
    public func handler(for method: DepositMethod) -> DepositHandler? {
        handlers[method]
    }

    /// Get all registered deposit methods.
    public var availableMethods: [DepositMethod] {
        handlers.keys.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Wallet Connection State

    /// Check if a deposit method is available and connected.
    public func isMethodAvailable(_ method: DepositMethod) -> Bool {
        guard let handler = handlers[method] else { return false }
        return handler.isAvailable
    }

    /// Check if a wallet-based method is connected.
    public func isWalletConnected(_ method: DepositMethod) -> Bool {
        guard let handler = handlers[method] else { return false }
        return handler.isConnected
    }

    /// Get the connected wallet address for a method.
    public func connectedWalletAddress(_ method: DepositMethod) -> String? {
        guard let handler = handlers[method] else { return nil }
        return handler.connectedAddress
    }

    // MARK: - Wallet Connection

    /// Connect a wallet for deposits.
    public func connectWallet(_ method: DepositMethod) async throws {
        guard let handler = handlers[method] else {
            throw DepositServiceError.handlerNotRegistered(method)
        }
        try await handler.connect()
    }

    /// Disconnect a wallet.
    public func disconnectWallet(_ method: DepositMethod) {
        handlers[method]?.disconnect()
    }

    // MARK: - Deposit Operations

    /// Initiate a deposit.
    ///
    /// - Parameters:
    ///   - method: The deposit method to use
    ///   - amountCents: Amount to deposit in cents
    /// - Returns: Transaction ID if available
    @discardableResult
    public func deposit(method: DepositMethod, amountCents: Int) async throws -> String? {
        guard let config = configuration else {
            throw DepositServiceError.notConfigured
        }

        guard let handler = handlers[method] else {
            throw DepositServiceError.handlerNotRegistered(method)
        }

        guard let destinationAddress = config.walletAddress(for: method.blockchain) else {
            throw DepositServiceError.missingWalletAddress(method.blockchain)
        }

        if method.requiresWalletConnection && !handler.isConnected {
            throw DepositServiceError.walletNotConnected(method)
        }

        isProcessing = true
        currentMethod = method
        errorMessage = nil
        delegate?.depositServiceDidInitiate(method: method, amountCents: amountCents)

        do {
            let transactionId = try await handler.deposit(
                amountCents: amountCents,
                destinationAddress: destinationAddress
            )

            let result = DepositResult(
                method: method,
                amountCents: amountCents,
                transactionId: transactionId,
                success: true
            )

            isProcessing = false
            currentMethod = nil
            lastResult = result
            delegate?.depositServiceDidComplete(result: result)

            return transactionId
        } catch {
            isProcessing = false
            currentMethod = nil
            errorMessage = error.localizedDescription
            delegate?.depositServiceDidFail(method: method, error: error)
            throw error
        }
    }

    /// Reset error state.
    public func clearError() {
        errorMessage = nil
    }
}
