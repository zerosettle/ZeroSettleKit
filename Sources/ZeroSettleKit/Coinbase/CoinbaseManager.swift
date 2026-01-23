//
//  CoinbaseManager.swift
//  ZeroSettleKit
//
//  Handles Coinbase Wallet connection for Base network transactions
//

import Foundation
import CoinbaseWalletSDK
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Manages Coinbase Wallet connections via SDK for Base network operations
@MainActor
public final class CoinbaseManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = CoinbaseManager()

    // MARK: - Published Properties

    /// Whether a Coinbase Wallet is currently connected
    @Published public private(set) var isConnected: Bool = false

    /// The connected wallet's address
    @Published public private(set) var address: String?

    /// Error message if connection or transaction failed
    @Published public private(set) var errorMessage: String?

    /// Whether a transaction is currently pending
    @Published public private(set) var isTransactionPending: Bool = false

    /// The last transaction hash
    @Published public private(set) var lastTransactionHash: String?

    /// Whether a connection attempt is in progress
    private var isConnecting: Bool = false

    // MARK: - Coinbase Wallet SDK

    private var cbwallet: CoinbaseWalletSDK {
        return CoinbaseWalletSDK.shared
    }

    // MARK: - Callbacks

    /// Callback when connected successfully
    public var onConnected: ((String) -> Void)?  // Called with wallet address

    /// Callback when connection fails
    public var onConnectionError: ((String) -> Void)?

    /// Callback when a transaction is sent successfully
    public var onTransactionSent: ((String) -> Void)?

    /// Callback when a transaction fails
    public var onTransactionError: ((String) -> Void)?

    // MARK: - Configuration

    /// Callback URL for universal link redirects (required by SDK)
    private var callbackURL: URL?

    // MARK: - UserDefaults Keys

    private enum StorageKeys {
        static let address = "CoinbaseManager.address"
        static let isConnected = "CoinbaseManager.isConnected"
    }

    // MARK: - Initialization

    private init() {
        loadPersistedState()
    }

    // MARK: - Configuration

    /// Configure the Coinbase manager with your app's settings
    /// - Parameter callbackURL: Universal link that your app can handle and route back to the SDK
    public func configure(callbackURL: URL) {
        self.callbackURL = callbackURL

        print("[Coinbase] Configuring SDK...")
        print("   - callback: \(callbackURL.absoluteString)")

        CoinbaseWalletSDK.configure(
            callback: callbackURL
        )

        print("[Coinbase] SDK configured")
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: StorageKeys.isConnected) {
            address = defaults.string(forKey: StorageKeys.address)

            if address != nil {
                isConnected = true
                print("[Coinbase] Restored connection state:")
                print("   - Address: \(address ?? "nil")")
            } else {
                print("[Coinbase] Incomplete persisted state, clearing")
                clearPersistedState()
            }
        }
    }

    private func persistConnectionState() {
        let defaults = UserDefaults.standard

        defaults.set(isConnected, forKey: StorageKeys.isConnected)
        defaults.set(address, forKey: StorageKeys.address)

        defaults.synchronize()
        print("[Coinbase] Persisted connection state")
    }

    private func clearPersistedState() {
        let defaults = UserDefaults.standard

        defaults.removeObject(forKey: StorageKeys.isConnected)
        defaults.removeObject(forKey: StorageKeys.address)

        defaults.synchronize()
        print("[Coinbase] Cleared persisted state")
    }

    // MARK: - Connection

    /// Initiate a connection to Coinbase Wallet
    public func connect() {
        print("═══════════════════════════════════════════")
        print("[Coinbase] CONNECT INITIATED")
        print("═══════════════════════════════════════════")

        print("   Current state:")
        print("      - Already connected (local flag): \(isConnected)")
        print("      - Has address: \(address != nil)")
        print("      - Connection in progress: \(isConnecting)")
        print("      - Transaction pending: \(isTransactionPending)")
        print("      - SDK isConnected(): \(cbwallet.isConnected())")

        // Prevent duplicate connections
        if isConnected {
            print("[Coinbase] Already connected! Skipping duplicate connection attempt")
            print("   Address: \(address ?? "nil")")
            print("═══════════════════════════════════════════")
            return
        }

        // Prevent concurrent connection attempts
        if isConnecting {
            print("[Coinbase] Connection already in progress! Skipping duplicate attempt")
            print("═══════════════════════════════════════════")
            return
        }

        isConnecting = true
        print("   Calling cbwallet.initiateHandshake()...")
        print("   This will open Coinbase Wallet app")
        print("   Waiting for user approval...")

#if canImport(UIKit)
        // Check if Coinbase Wallet is installed to avoid silent no-op
        if let cbwalletURL = URL(string: "cbwallet://"), !UIApplication.shared.canOpenURL(cbwalletURL) {
            let msg = "Coinbase Wallet app is not installed. Please install it to connect."
            print("[Coinbase] \(msg)")
            isConnecting = false
            errorMessage = msg
            onConnectionError?(msg)
            return
        }
        print("[Coinbase] Coinbase Wallet app is installed (cbwallet:// is openable)")
#endif

        // Initiate handshake on main thread (SDK expects UI context)
        DispatchQueue.main.async {
            print("[Coinbase] Dispatching initiateHandshake on main thread")
            do {
                if let callback = self.callbackURL {
                    print("[Coinbase] Using callback: \(callback.absoluteString)")
                } else {
                    print("[Coinbase] No callbackURL configured; handshake may fail")
                }

                // Reset any stale session to force a fresh connect UI
                let resetResult = self.cbwallet.resetSession()
                print("[Coinbase] resetSession result: \(resetResult)")

                try self.cbwallet.initiateHandshake(
                    initialActions: [
                        Action(jsonRpc: .eth_requestAccounts)
                    ]
                ) { [weak self] result, account in
                    guard let self = self else { return }

                    Task { @MainActor in
                        self.isConnecting = false

                        print("[Coinbase] Received handshake callback")

                        switch result {
                        case .success(let response):
                            print("[Coinbase] Connection successful")
                            print("   Response: \(response)")

                            guard let account = account else {
                                let msg = "No account returned from Coinbase Wallet"
                                print("[Coinbase] \(msg)")
                                self.errorMessage = msg
                                self.onConnectionError?(msg)
                                print("═══════════════════════════════════════════")
                                return
                            }

                            print("[Coinbase] Using account")
                            print("   Address: \(account.address)")
                            print("   Chain: \(account.chain ?? "unknown")")

                            self.address = account.address
                            self.isConnected = true
                            self.errorMessage = nil

                            self.persistConnectionState()
                            self.onConnected?(account.address)

                            print("═══════════════════════════════════════════")
                            print("COINBASE WALLET CONNECTED SUCCESSFULLY!")
                            print("   Address: \(account.address)")
                            print("   Chain: \(account.chain ?? "unknown")")
                            print("═══════════════════════════════════════════")

                        case .failure(let error):
                            print("═══════════════════════════════════════════")
                            print("[Coinbase] CONNECTION FAILED")
                            print("═══════════════════════════════════════════")
                            print("   Error: \(error)")
                            print("   Error localized: \(error.localizedDescription)")

                            let errorMsg = "Connection failed: \(error.localizedDescription)"
                            self.errorMessage = errorMsg
                            self.onConnectionError?(errorMsg)

                            print("═══════════════════════════════════════════")
                        }
                    }
                }
            } catch {
                self.isConnecting = false
                let msg = "Failed to initiate Coinbase handshake: \(error.localizedDescription)"
                print("[Coinbase] \(msg)")
                print("   Error: \(error)")
                self.errorMessage = msg
                self.onConnectionError?(msg)
            }
        }
    }

    // MARK: - Send USDC on Base

    /// Send USDC on Base network
    /// - Parameters:
    ///   - to: Recipient address
    ///   - amountUSDC: Amount in USDC (e.g., 5.0 for $5.00)
    /// - Returns: The transaction hash
    public func sendUSDC(to: String, amountUSDC: Double) async -> String? {
        guard isConnected, let fromAddress = address else {
            errorMessage = "Not connected to Coinbase Wallet"
            onTransactionError?(errorMessage!)
            print("[Coinbase] Not connected")
            return nil
        }

        // Base USDC contract address
        let usdcAddress = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

        print("[Coinbase] Preparing USDC transaction on Base...")
        print("   - From: \(fromAddress)")
        print("   - To: \(to)")
        print("   - Amount: $\(amountUSDC) USDC")
        print("   - USDC Contract: \(usdcAddress)")

        isTransactionPending = true

        // USDC has 6 decimals
        let baseUnits = UInt64(amountUSDC * 1_000_000)
        let amountHex = String(format: "0x%x", baseUnits)

        // ERC-20 transfer function signature: transfer(address,uint256)
        let functionSignature = "0xa9059cbb"

        // Encode parameters:
        // - to address (32 bytes, left-padded)
        // - amount (32 bytes, left-padded)
        let toAddress = to.replacingOccurrences(of: "0x", with: "")
        let amountValue = amountHex.replacingOccurrences(of: "0x", with: "")

        let toAddressPadded = String(repeating: "0", count: 64 - toAddress.count) + toAddress
        let amountPadded = String(repeating: "0", count: 64 - amountValue.count) + amountValue

        let data = functionSignature + toAddressPadded + amountPadded

        print("   - Data: \(data)")

        return await withCheckedContinuation { continuation in
            cbwallet.makeRequest(
                Request(
                    actions: [
                        Action(
                            jsonRpc: .eth_sendTransaction(
                                fromAddress: fromAddress,
                                toAddress: usdcAddress,
                                weiValue: "0x0",  // No ETH sent, just token transfer
                                data: data,
                                nonce: nil,
                                gasPriceInWei: nil,
                                maxFeePerGas: nil,
                                maxPriorityFeePerGas: nil,
                                gasLimit: nil,
                                chainId: "8453",  // Base mainnet
                                actionSource: nil
                            )
                        )
                    ]
                )
            ) { [weak self] result in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                Task { @MainActor in
                    switch result {
                    case .success(let response):
                        // Extract transaction hash from response
                        if let content = response.content as? [String: Any],
                           let result = content["result"] as? String {
                            self.lastTransactionHash = result
                            self.isTransactionPending = false
                            self.errorMessage = nil

                            self.onTransactionSent?(result)

                            print("═══════════════════════════════════════════════")
                            print("TRANSACTION SENT SUCCESSFULLY!")
                            print("   Hash: \(result)")
                            print("   View on BaseScan:")
                            print("   https://basescan.org/tx/\(result)")
                            print("═══════════════════════════════════════════════")

                            continuation.resume(returning: result)
                        } else {
                            let errorMsg = "Invalid response format"
                            self.errorMessage = errorMsg
                            self.isTransactionPending = false
                            self.onTransactionError?(errorMsg)
                            print("[Coinbase] \(errorMsg)")
                            continuation.resume(returning: nil)
                        }

                    case .failure(let error):
                        let errorMsg = "Transaction failed: \(error.localizedDescription)"
                        self.errorMessage = errorMsg
                        self.isTransactionPending = false
                        self.onTransactionError?(errorMsg)
                        print("[Coinbase] Transaction failed: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    // MARK: - Disconnect

    public func disconnect() {
        clearPersistedState()

        isConnected = false
        address = nil
        errorMessage = nil
        isTransactionPending = false
        lastTransactionHash = nil

        print("[Coinbase] Disconnected")
    }

    // MARK: - URL Handling

    /// Handle Coinbase Wallet callback URLs
    /// Call this from your AppDelegate's application(_:open:options:) method
    /// - Parameter url: The callback URL
    /// - Returns: Whether the URL was handled
    public func handleUrl(_ url: URL) -> Bool {
        print("═══════════════════════════════════════════")
        print("[Coinbase] handleUrl called")
        print("═══════════════════════════════════════════")
        print("   URL: \(url.absoluteString)")

        do {
            let handled = try cbwallet.handleResponse(url)
            print("   Handled by SDK: \(handled)")
            print("═══════════════════════════════════════════")
            return handled
        } catch {
            print("   Error handling URL: \(error)")
            print("═══════════════════════════════════════════")
            return false
        }
    }
    
    // MARK: - Helpers

    /// Format an address for display (0x1234...5678)
    public func formatAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    /// Format USDC amount
    public func formatUSDC(baseUnits: UInt64) -> String {
        return String(format: "$%.2f", Double(baseUnits) / 1_000_000.0)
    }
}

// MARK: - Coinbase Wallet Errors

/// Errors that can occur during Coinbase Wallet operations
public enum CoinbaseWalletError: LocalizedError {
    case notConfigured
    case notConnected
    case connectionFailed(String)
    case transactionFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Coinbase Wallet SDK is not configured"
        case .notConnected:
            return "Coinbase Wallet is not connected"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .transactionFailed(let message):
            return "Transaction failed: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

