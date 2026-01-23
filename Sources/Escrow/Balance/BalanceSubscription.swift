//
//  BalanceSubscription.swift
//  ZeroSettleEscrow
//
//  WebSocket subscription for real-time USDC balance updates.
//

import Foundation
import ZeroSettleCore
import ZeroSettleBlockchain

// MARK: - Balance Subscription

/// Manages a WebSocket subscription to monitor USDC token account balance changes.
/// Uses Solana's `accountSubscribe` RPC method for real-time updates.
internal final class BalanceSubscription: @unchecked Sendable {

    // MARK: - Properties

    weak var delegate: BalanceUpdateDelegate?

    private let environment: NetworkEnvironment
    private let wallet: SolanaAddress
    private let tokenMint: SolanaAddress
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var subscriptionId: Int?
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var pingTask: Task<Void, Never>?
    private let pingInterval: UInt64 = 20_000_000_000  // 20 seconds

    // MARK: - Initialization

    init(
        environment: NetworkEnvironment,
        wallet: SolanaAddress,
        tokenMint: SolanaAddress
    ) {
        self.environment = environment
        self.wallet = wallet
        self.tokenMint = tokenMint
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    /// Connect to the Solana WebSocket and subscribe to balance updates.
    func connect() async throws {
        guard !isConnected else { return }

        let url = environment.solanaWebSocketURL
        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        isConnected = true
        reconnectAttempts = 0

        Logger.info("WebSocket connecting to \(url)", category: .escrow)

        // Start receiving messages
        receiveMessages()

        // Subscribe to the token account
        try await subscribeToTokenAccount()

        // Start ping loop to keep connection alive
        startPingLoop()

        // Also fetch current balance immediately
        await fetchCurrentBalance()
    }

    /// Send periodic pings to keep the WebSocket connection alive.
    /// Solana RPC WebSockets timeout after ~30 seconds of inactivity.
    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.pingInterval ?? 20_000_000_000)
                    guard let self, self.isConnected else { break }
                    self.webSocket?.sendPing { error in
                        if let error {
                            Logger.debug("WebSocket ping failed: \(error)", category: .escrow)
                        }
                    }
                } catch {
                    break
                }
            }
        }
    }

    /// Disconnect from the WebSocket.
    func disconnect() {
        isConnected = false
        subscriptionId = nil

        // Stop ping loop
        pingTask?.cancel()
        pingTask = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        session?.invalidateAndCancel()
        session = nil

        Logger.info("WebSocket disconnected", category: .escrow)
    }

    // MARK: - Subscription

    private func subscribeToTokenAccount() async throws {
        // First, derive the Associated Token Account (ATA) address
        let ataAddress = try deriveATA(owner: wallet, mint: tokenMint)

        // Subscribe to account changes
        let subscribeRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "accountSubscribe",
            "params": [
                ataAddress.base58,
                [
                    "encoding": "jsonParsed",
                    "commitment": "confirmed"
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: subscribeRequest)
        let message = URLSessionWebSocketTask.Message.data(data)

        try await webSocket?.send(message)
        Logger.debug("Subscribed to token account: \(ataAddress.abbreviated)", category: .escrow)
    }

    private func receiveMessages() {
        webSocket?.receive { [weak self] result in
            guard let self, self.isConnected else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()

            case .failure(let error):
                Logger.error("WebSocket receive error: \(error)", category: .escrow)
                self.handleDisconnection(error: error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Check for subscription confirmation
        if let result = json["result"] as? Int, subscriptionId == nil {
            subscriptionId = result
            Logger.debug("Balance subscription confirmed: \(result)", category: .escrow)
            return
        }

        // Check for account notification
        if let params = json["params"] as? [String: Any],
           let result = params["result"] as? [String: Any],
           let value = result["value"] as? [String: Any] {
            parseAccountValue(value)
        }
    }

    private func parseAccountValue(_ value: [String: Any]) {
        // For SPL Token accounts, the balance is in parsed data
        if let data = value["data"] as? [String: Any],
           let parsed = data["parsed"] as? [String: Any],
           let info = parsed["info"] as? [String: Any],
           let tokenAmount = info["tokenAmount"] as? [String: Any],
           let amountString = tokenAmount["amount"] as? String,
           let amount = UInt64(amountString) {

            Task { @MainActor [weak self] in
                self?.delegate?.balanceDidUpdate(amount)
            }
        }
    }

    // MARK: - Manual Fetch

    /// Fetch the current balance via RPC (not WebSocket).
    /// Used for initial balance and fallback.
    func fetchCurrentBalance() async {
        do {
            let ataAddress = try deriveATA(owner: wallet, mint: tokenMint)
            let balance = try await fetchTokenAccountBalance(ataAddress)

            Task { @MainActor [weak self] in
                self?.delegate?.balanceDidUpdate(balance)
            }
        } catch {
            Logger.error("Failed to fetch current balance: \(error)", category: .escrow)
            Task { @MainActor [weak self] in
                self?.delegate?.balanceSubscriptionFailed(error)
            }
        }
    }

    private func fetchTokenAccountBalance(_ account: SolanaAddress) async throws -> UInt64 {
        let url = environment.solanaRpcURL

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenAccountBalance",
            "params": [account.base58]
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request)

        let (data, _) = try await URLSession.shared.data(for: urlRequest)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let value = result["value"] as? [String: Any],
              let amountString = value["amount"] as? String,
              let amount = UInt64(amountString) else {
            throw BalanceSubscriptionError.invalidResponse
        }

        return amount
    }

    // MARK: - Reconnection

    private func handleDisconnection(error: Error) {
        isConnected = false
        subscriptionId = nil

        guard reconnectAttempts < maxReconnectAttempts else {
            Logger.error("Max reconnection attempts reached", category: .escrow)
            Task { @MainActor [weak self] in
                self?.delegate?.balanceSubscriptionFailed(BalanceSubscriptionError.connectionLost)
            }
            return
        }

        reconnectAttempts += 1
        let delay = Double(reconnectAttempts) * 2.0 // Exponential backoff

        Logger.info("Reconnecting in \(delay)s (attempt \(reconnectAttempts))", category: .escrow)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            try? await self.connect()
        }
    }

    // MARK: - ATA Derivation

    private func deriveATA(owner: SolanaAddress, mint: SolanaAddress) throws -> SolanaAddress {
        // Use PDADerivation from ZeroSettleBlockchain module
        let ataAddress = try PDADerivation.deriveATA(wallet: owner.base58, mint: mint.base58)
        Logger.debug("Derived ATA address: \(ataAddress)", category: .escrow)
        return SolanaAddress(trusted: ataAddress)
    }
}

// MARK: - Errors

enum BalanceSubscriptionError: Error, LocalizedError {
    case connectionFailed
    case connectionLost
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to Solana WebSocket"
        case .connectionLost:
            return "Lost connection to Solana WebSocket"
        case .invalidResponse:
            return "Invalid response from Solana RPC"
        }
    }
}
