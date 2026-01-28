//
//  MetaMaskManager.swift
//  ZeroSettleKit
//
//  Handles MetaMask wallet connection for Ethereum transactions
//

import Foundation
import metamask_ios_sdk
import Combine
import UIKit

/// Manages MetaMask wallet connections via deeplink for Ethereum operations
@MainActor
public final class MetaMaskManager: ObservableObject {

    // MARK: - Debug Tracking

    private static var connectCallCount: Int = 0

    // MARK: - Singleton

    public static let shared = MetaMaskManager()

    // MARK: - Published Properties

    /// Whether a MetaMask wallet is currently connected
    @Published public private(set) var isConnected: Bool = false

    /// The connected wallet's Ethereum address
    @Published public private(set) var account: String?

    /// Current chain ID (e.g., "0x1" for Ethereum mainnet)
    @Published public private(set) var chainId: String?

    /// Error message if connection or transaction failed
    @Published public private(set) var errorMessage: String?

    /// Whether a transaction is currently pending
    @Published public private(set) var isTransactionPending: Bool = false

    /// The last transaction hash
    @Published public private(set) var lastTransactionHash: String?

    /// Whether a connection attempt is in progress
    private var isConnecting: Bool = false

    // MARK: - MetaMask SDK

    private var metamaskSDK: MetaMaskSDK?

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

    /// App URL scheme for redirects back to the app
    private var dappScheme: String = "zerosettle"

    /// Infura API key for RPC access
    private var infuraAPIKey: String?

    // MARK: - UserDefaults Keys

    private enum StorageKeys {
        static let account = "MetaMaskManager.account"
        static let chainId = "MetaMaskManager.chainId"
        static let isConnected = "MetaMaskManager.isConnected"
    }

    // MARK: - Initialization

    private init() {
        loadPersistedState()
    }

    // MARK: - Configuration

    /// Configure the MetaMask manager with your app's settings
    /// - Parameters:
    ///   - dappScheme: Your app's URL scheme (e.g., "dubdapp")
    ///   - appName: Your app's display name
    ///   - appURL: Your app's website URL
    ///   - infuraAPIKey: Your Infura API key (optional)
    public func configure(
        dappScheme: String,
        appName: String,
        appURL: String,
        infuraAPIKey: String? = nil
    ) {
        self.dappScheme = dappScheme
        self.infuraAPIKey = infuraAPIKey

        let appMetadata = AppMetadata(name: appName, url: appURL)

        let sdkOptions = SDKOptions(
            infuraAPIKey: infuraAPIKey ?? "",
            readonlyRPCMap: infuraAPIKey != nil ? [
                "0x1": "https://mainnet.infura.io/v3/\(infuraAPIKey!)"
            ] : [:]
        )

        metamaskSDK = MetaMaskSDK.shared(
            appMetadata,
            transport: .deeplinking(dappScheme: dappScheme),
            sdkOptions: sdkOptions
        )

        Logger.info("MetaMask SDK configured: scheme=\(dappScheme)", category: .wallet)
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: StorageKeys.isConnected) {
            account = defaults.string(forKey: StorageKeys.account)
            chainId = defaults.string(forKey: StorageKeys.chainId)

            if account != nil {
                isConnected = true
                print("[MetaMask] Restored connection state:")
                print("   - Account: \(account ?? "nil")")
                print("   - Chain ID: \(chainId ?? "nil")")
            } else {
                print("[MetaMask] Incomplete persisted state, clearing")
                clearPersistedState()
            }
        }
    }

    private func persistConnectionState() {
        let defaults = UserDefaults.standard

        defaults.set(isConnected, forKey: StorageKeys.isConnected)
        defaults.set(account, forKey: StorageKeys.account)
        defaults.set(chainId, forKey: StorageKeys.chainId)

        defaults.synchronize()
        print("[MetaMask] Persisted connection state")
    }

    private func clearPersistedState() {
        let defaults = UserDefaults.standard

        defaults.removeObject(forKey: StorageKeys.isConnected)
        defaults.removeObject(forKey: StorageKeys.account)
        defaults.removeObject(forKey: StorageKeys.chainId)

        defaults.synchronize()
        print("[MetaMask] Cleared persisted state")
    }

    // MARK: - Connection

    /// Initiate a connection to MetaMask wallet
    public func connect() async {
        MetaMaskManager.connectCallCount += 1
        let callNumber = MetaMaskManager.connectCallCount

        print("-------------------------------------------")
        print("[MetaMask] CONNECT INITIATED (Call #\(callNumber))")
        print("-------------------------------------------")
        print("   Call Stack:")
        Thread.callStackSymbols.prefix(15).forEach { print("      \($0)") }

        guard let sdk = metamaskSDK else {
            let msg = "MetaMask SDK not configured. Call configure() first."
            errorMessage = msg
            onConnectionError?(msg)
            print("[MetaMask] SDK not configured")
            print("   Solution: Call MetaMaskManager.shared.configure() before connect()")
            print("-------------------------------------------")
            return
        }

        print("[MetaMask] SDK is configured")
        print("   Current state:")
        print("      - Already connected: \(isConnected)")
        print("      - Has account: \(account != nil)")
        print("      - Connection in progress: \(isConnecting)")
        print("      - Transaction pending: \(isTransactionPending)")

        // Prevent duplicate connections
        if isConnected {
            print("[MetaMask] Already connected! Skipping duplicate connection attempt")
            print("   Account: \(account ?? "nil")")
            print("-------------------------------------------")
            return
        }

        // Prevent concurrent connection attempts
        if isConnecting {
            print("[MetaMask] Connection already in progress! Skipping duplicate attempt")
            print("   This prevents MetaMask from opening twice")
            print("-------------------------------------------")
            return
        }

        isConnecting = true
        print("   Calling sdk.connect()...")
        print("   This will open MetaMask app via deeplink")
        print("   Waiting for user approval...")

        let connectResult = await sdk.connect()

        print("[MetaMask] Received connect result")
        print("   Result type: \(type(of: connectResult))")

        // Handle Result type from SDK
        switch connectResult {
        case .success(let accounts):
            print("[MetaMask] Connection successful")
            print("   Accounts type: \(type(of: accounts))")
            print("   Accounts received: \(accounts)")
            print("   Number of accounts: \(accounts.count)")

            guard let firstAccount = accounts.first else {
                isConnecting = false
                let msg = "No accounts returned from MetaMask"
                print("[MetaMask] \(msg)")
                errorMessage = msg
                onConnectionError?(msg)
                print("-------------------------------------------")
                return
            }

            print("[MetaMask] Using first account")
            print("   Account: \(firstAccount)")
            print("   Account length: \(firstAccount.count) characters")

            // Validate address format (Ethereum or Solana)
            if firstAccount.hasPrefix("0x") && firstAccount.count == 42 {
                print("   Valid Ethereum address format")
            } else if firstAccount.count >= 32 && firstAccount.count <= 44 {
                print("   Valid Solana address format (base58)")
            } else {
                print("   Unusual address format")
            }

            account = firstAccount
            isConnected = true
            isConnecting = false
            errorMessage = nil

            // Try to get chainId from SDK directly (should be set from connection response)
            print("   Checking SDK for chainId...")
            print("   SDK.chainId: \(sdk.chainId)")

            // Set our chainId from SDK if available and not empty
            if !sdk.chainId.isEmpty {
                chainId = sdk.chainId
                print("   Got chainId from SDK: \(sdk.chainId)")
            } else {
                // Default to Ethereum mainnet if not available
                chainId = "0x1"
                print("   ChainId not available from SDK, defaulting to 0x1 (Ethereum)")
            }

            print("   Persisting connection state...")
            persistConnectionState()

            print("   Calling onConnected callback...")
            onConnected?(firstAccount)

            print("-------------------------------------------")
            print("METAMASK WALLET CONNECTED SUCCESSFULLY!")
            print("   Account: \(firstAccount)")
            print("   Chain ID: \(chainId ?? "unknown")")
            print("-------------------------------------------")

        case .failure(let error):
            isConnecting = false
            print("-------------------------------------------")
            print("[MetaMask] CONNECTION FAILED")
            print("-------------------------------------------")
            print("   Error: \(error)")
            print("   Error Type: \(type(of: error))")
            print("   Error localized: \(error.localizedDescription)")

            let errorMsg = "Connection failed: \(error.localizedDescription)"
            errorMessage = errorMsg
            onConnectionError?(errorMsg)

            print("-------------------------------------------")
        }
    }

    // MARK: - Chain Information

    /// Fetch the current chain ID from MetaMask
    private func fetchChainId() async {
        guard let sdk = metamaskSDK else { return }

        let result = await sdk.getChainId()
        switch result {
        case .success(let fetchedChainId):
            chainId = fetchedChainId
            print("   - Chain ID: \(fetchedChainId)")
        case .failure(let error):
            print("   Failed to fetch chain ID: \(error)")
        }
    }

    /// Get the current chain ID
    /// - Returns: The chain ID (e.g., "0x1" for Ethereum mainnet)
    public func getChainId() async -> String? {
        guard let sdk = metamaskSDK else {
            print("[MetaMask] SDK not configured")
            return nil
        }

        let result = await sdk.getChainId()
        switch result {
        case .success(let id):
            chainId = id
            return id
        case .failure(let error):
            print("[MetaMask] Failed to get chain ID: \(error)")
            return nil
        }
    }

    // MARK: - Balance

    /// Get the ETH balance for an address
    /// - Parameters:
    ///   - address: The Ethereum address
    ///   - block: Block parameter (e.g., "latest")
    /// - Returns: The balance as a hex string
    public func getEthBalance(address: String? = nil, block: String = "latest") async -> String? {
        guard let sdk = metamaskSDK else {
            print("[MetaMask] SDK not configured")
            return nil
        }

        let addr = address ?? sdk.account

        let result = await sdk.getEthBalance(address: addr, block: block)
        switch result {
        case .success(let balance):
            print("[MetaMask] ETH balance for \(addr): \(balance)")
            return balance
        case .failure(let error):
            print("[MetaMask] Failed to get ETH balance: \(error)")
            return nil
        }
    }

    // MARK: - Send Transaction

    /// Send an Ethereum transaction
    /// - Parameters:
    ///   - to: Recipient address
    ///   - value: Value in wei (hex string)
    ///   - data: Transaction data (optional, hex string) - REQUIRED for ERC-20 transfers
    ///   - gas: Gas limit (optional, hex string)
    ///   - gasPrice: Gas price (optional, hex string)
    /// - Returns: The transaction hash
    public func sendTransaction(
        to: String,
        value: String,
        data: String? = nil,
        gas: String? = nil,
        gasPrice: String? = nil
    ) async -> String? {
        guard let sdk = metamaskSDK, isConnected else {
            errorMessage = "Not connected to MetaMask"
            onTransactionError?(errorMessage!)
            print("[MetaMask] Not connected")
            return nil
        }

        print("[MetaMask] Preparing transaction...")
        print("   - From: \(sdk.account)")
        print("   - To: \(to)")
        print("   - Value: \(value)")
        if let data = data {
            print("   - Data: \(data.prefix(50))... (\(data.count) chars)")
        }

        isTransactionPending = true

        // Build transaction params as array of dictionaries (per MetaMask SDK docs)
        // eth_sendTransaction expects params: [{ from, to, value, data, ... }]
        var txDict: [String: String] = [
            "from": sdk.account,
            "to": to,
            "value": value
        ]

        // Include data for ERC-20 token transfers
        if let data = data {
            txDict["data"] = data
        }

        // Create the eth_sendTransaction request
        let txRequest = EthereumRequest(
            method: "eth_sendTransaction",
            params: [txDict]
        )

        let result: Result<String, RequestError> = await sdk.request(txRequest)

        switch result {
        case .success(let txHash):
            lastTransactionHash = txHash
            isTransactionPending = false
            errorMessage = nil

            onTransactionSent?(txHash)

            print("-----------------------------------------------")
            print("TRANSACTION SENT SUCCESSFULLY!")
            print("   Hash: \(txHash)")
            print("   View on Etherscan:")
            print("   https://etherscan.io/tx/\(txHash)")
            print("-----------------------------------------------")

            return txHash

        case .failure(let error):
            let errorMsg = "Transaction failed: \(error.localizedDescription)"
            errorMessage = errorMsg
            isTransactionPending = false
            onTransactionError?(errorMsg)
            print("[MetaMask] Transaction failed: \(error)")
            return nil
        }
    }

    // MARK: - Generic RPC Request

    /// Make a generic JSON-RPC request
    /// - Parameter request: The Ethereum request with method and params
    /// - Returns: The response result
    public func request<T: CodableData>(_ method: String, params: [T]) async -> Result<String, Error> {
        guard let sdk = metamaskSDK else {
            print("[MetaMask] SDK not configured")
            return .failure(MetaMaskError.notConfigured)
        }

        print("[MetaMask] Making request: \(method)")

        let ethRequest = EthereumRequest(method: method, params: params)
        let result = await sdk.request(ethRequest)

        switch result {
        case .success(let response):
            print("   Request successful")
            return .success(response)
        case .failure(let error):
            print("   Request failed: \(error)")
            return .failure(error)
        }
    }

    // MARK: - ERC-20 Token Operations

    /// Send ERC-20 tokens
    /// - Parameters:
    ///   - tokenAddress: The ERC-20 token contract address
    ///   - to: Recipient address
    ///   - amount: Amount in token's base units (hex string)
    /// - Returns: The transaction hash
    public func sendERC20Token(
        tokenAddress: String,
        to: String,
        amount: String
    ) async -> String? {
        // ERC-20 transfer function signature: transfer(address,uint256)
        let functionSignature = "0xa9059cbb"

        // Encode parameters:
        // - to address (32 bytes, left-padded)
        // - amount (32 bytes, left-padded)
        let toAddress = to.replacingOccurrences(of: "0x", with: "")
        let amountValue = amount.replacingOccurrences(of: "0x", with: "")

        let toAddressPadded = String(repeating: "0", count: 64 - toAddress.count) + toAddress
        let amountPadded = String(repeating: "0", count: 64 - amountValue.count) + amountValue

        let data = functionSignature + toAddressPadded + amountPadded

        print("[MetaMask] Sending ERC-20 token...")
        print("   - Token: \(tokenAddress)")
        print("   - To: \(to)")
        print("   - Amount: \(amount)")

        return await sendTransaction(
            to: tokenAddress,
            value: "0x0",  // No ETH sent, just token transfer
            data: data
        )
    }

    /// Send USDC on Ethereum using MetaMask Mobile deeplink (simpler than SDK)
    /// - Parameters:
    ///   - to: Recipient address
    ///   - amountUSDC: Amount in USDC (e.g., 5.0 for $5.00)
    ///   - chainId: Chain ID (defaults to Ethereum mainnet "0x1")
    /// - Returns: The transaction hash
    public func sendUSDC(
        to: String,
        amountUSDC: Double,
        chainId: String = "0x1"
    ) async -> String? {
        // USDC contract address on Ethereum mainnet
        let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"

        guard chainId == "0x1" else {
            errorMessage = "USDC transfers only supported on Ethereum mainnet"
            onTransactionError?(errorMessage!)
            print("[MetaMask] USDC not supported on chain \(chainId)")
            return nil
        }

        // USDC has 6 decimals
        let baseUnits = UInt64(amountUSDC * 1_000_000)
        let amountHex = String(format: "0x%x", baseUnits)

        print("[MetaMask] Sending USDC...")
        print("   - Amount: $\(amountUSDC) (\(baseUnits) base units)")
        print("   - To: \(to)")
        print("   - USDC Contract: \(usdcAddress)")

        return await sendERC20Token(
            tokenAddress: usdcAddress,
            to: to,
            amount: amountHex
        )
    }

    // MARK: - MetaMask Mobile Deeplink (Simplified USDC Transfer)

    /// Send USDC using MetaMask Mobile deeplink (no SDK required, prefills transaction UI)
    /// This opens MetaMask Mobile with a prefilled USDC transfer on Ethereum mainnet
    /// - Parameters:
    ///   - to: Recipient Ethereum address (0x...)
    ///   - amountUSDC: Amount in USDC (e.g., 3.0 for $3.00)
    /// - Note: This only works with MetaMask Mobile app installed
    /// - Note: USDC on Ethereum mainnet only (ERC-20)
    public func sendUSDCViaDeeplink(
        to: String,
        amountUSDC: Double
    ) {
        // USDC contract on Ethereum mainnet
        let usdcContract = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        let chainId = "1" // Ethereum mainnet

        // Convert USDC to base units (6 decimals)
        let baseUnits = UInt64(amountUSDC * 1_000_000)

        print("-----------------------------------------------")
        print("[MetaMask] Initiating deeplink USDC transfer")
        print("-----------------------------------------------")
        print("   Recipient: \(to)")
        print("   Amount: $\(amountUSDC) USDC")
        print("   Base units: \(baseUnits)")
        print("   USDC contract: \(usdcContract)")
        print("   Chain ID: \(chainId) (Ethereum mainnet)")

        // Validate Ethereum address
        guard to.hasPrefix("0x") && to.count == 42 else {
            let error = "Invalid Ethereum address format"
            print("[MetaMask] \(error)")
            errorMessage = error
            onTransactionError?(error)
            return
        }

        // Build MetaMask Mobile deeplink
        // Format: https://link.metamask.io/transfer?address={recipient}&uint256={amount}&asset={token}@{chainId}
        let urlString = "https://link.metamask.io/transfer?address=\(to)&uint256=\(baseUnits)&asset=\(usdcContract)@\(chainId)"

        guard let url = URL(string: urlString) else {
            let error = "Failed to construct MetaMask deeplink URL"
            print("[MetaMask] \(error)")
            errorMessage = error
            onTransactionError?(error)
            return
        }

        print("   Deeplink URL: \(urlString)")
        print("   Opening MetaMask Mobile...")

        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { success in
                if success {
                    print("[MetaMask] Successfully opened MetaMask Mobile")
                    print("   User will confirm transaction in MetaMask")
                    print("-----------------------------------------------")
                } else {
                    let error = "Failed to open MetaMask Mobile (app not installed?)"
                    print("[MetaMask] \(error)")
                    print("   Make sure MetaMask Mobile is installed")
                    print("-----------------------------------------------")

                    DispatchQueue.main.async {
                        self.errorMessage = error
                        self.onTransactionError?(error)
                    }
                }
            }
        }

        // Note: We can't track the transaction result directly with deeplinks
        // The user completes the transaction in MetaMask and returns to the app
        // You would typically check balances or use backend verification
    }


    // MARK: - Disconnect

    public func disconnect() {
        clearPersistedState()

        isConnected = false
        account = nil
        chainId = nil
        errorMessage = nil
        isTransactionPending = false
        lastTransactionHash = nil

        print("[MetaMask] Disconnected")
    }

    // MARK: - URL Handling

    /// Handle MetaMask callback URLs
    /// Call this from your AppDelegate's application(_:open:options:) method
    /// - Parameter url: The callback URL
    /// - Returns: Whether the URL was handled
    public func handleUrl(_ url: URL) -> Bool {
        print("-------------------------------------------")
        print("[MetaMask] handleUrl called")
        print("-------------------------------------------")
        print("   URL: \(url.absoluteString)")
        print("   Scheme: \(url.scheme ?? "nil")")
        print("   Host: \(url.host ?? "nil")")
        print("   Path: \(url.path)")

        guard let sdk = metamaskSDK else {
            print("[MetaMask] SDK not configured, cannot handle URL")
            print("-------------------------------------------")
            return false
        }

        print("   SDK Status:")
        print("      - SDK exists: true")
        print("      - Connected: \(isConnected)")
        print("      - Account: \(account ?? "nil")")
        print("      - Chain ID: \(chainId ?? "nil")")

        // Parse URL components to check for errors
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            print("   Callback Query Parameters:")

            // Check for common error/success indicators
            var hasError = false
            var hasSuccess = false

            for item in queryItems {
                let value = item.value ?? "nil"
                let displayValue = value.count > 100 ? "\(value.prefix(100))..." : value
                print("      - \(item.name): \(displayValue)")

                // Try to decode base64 message parameter
                if item.name == "message", let value = item.value {
                    print("         Decoding base64 message...")
                    if let decodedData = Data(base64Encoded: value),
                       let decodedString = String(data: decodedData, encoding: .utf8) {
                        print("         Decoded message: \(decodedString)")

                        // Try to parse as JSON
                        if let jsonObject = try? JSONSerialization.jsonObject(with: decodedData, options: []) {
                            print("         Message JSON structure:")
                            if let dict = jsonObject as? [String: Any] {
                                for (key, val) in dict {
                                    print("            - \(key): \(val)")
                                    // If there's nested data, show it
                                    if let nestedDict = val as? [String: Any] {
                                        for (nestedKey, nestedVal) in nestedDict {
                                            print("               - \(nestedKey): \(nestedVal)")
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        print("         Failed to decode base64 message")
                    }
                }

                if item.name.lowercased().contains("error") {
                    hasError = true
                    print("         ERROR DETECTED")
                }
                if item.name.lowercased().contains("success") || item.name.lowercased().contains("result") {
                    hasSuccess = true
                }
            }

            if hasError {
                print("   Callback contains error parameter")
            } else if hasSuccess {
                print("   Callback appears successful")
            }
        }

        print("   Forwarding to MetaMask SDK...")
        sdk.handleUrl(url)

        print("[MetaMask] URL forwarded to SDK")
        print("-------------------------------------------")

        return true
    }

    // MARK: - Helpers

    /// Format an Ethereum address for display (0x1234...5678)
    public func formatAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    /// Format USDC amount
    public func formatUSDC(baseUnits: UInt64) -> String {
        return String(format: "$%.2f", Double(baseUnits) / 1_000_000.0)
    }

    /// Convert ETH wei to ETH
    public func weiToEth(_ wei: String) -> Double? {
        guard let weiValue = UInt64(wei.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            return nil
        }
        return Double(weiValue) / 1_000_000_000_000_000_000.0
    }
}

// MARK: - MetaMask Errors

/// Errors that can occur during MetaMask operations
public enum MetaMaskError: LocalizedError {
    case notConfigured
    case notConnected
    case connectionFailed(String)
    case transactionFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "MetaMask SDK is not configured"
        case .notConnected:
            return "MetaMask wallet is not connected"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .transactionFailed(let message):
            return "Transaction failed: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

