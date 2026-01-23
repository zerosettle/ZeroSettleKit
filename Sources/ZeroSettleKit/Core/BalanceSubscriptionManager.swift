//
//  BalanceSubscriptionManager.swift
//  ZeroSettleKit
//
//  Subscribes to Solana account changes via WebSocket for real-time balance updates.
//

import Foundation
import Combine

public class BalanceSubscriptionManager: ObservableObject {

    public static let shared = BalanceSubscriptionManager()

    @Published public private(set) var balanceCents: Int = 0
    @Published public private(set) var isSubscribed: Bool = false

    public var balancePublisher: AnyPublisher<Int, Never> {
        $balanceCents.eraseToAnyPublisher()
    }

    private var webSocket: URLSessionWebSocketTask?
    private var subscriptionId: Int?
    private var currentTokenAccount: String?
    private var reconnectTask: Task<Void, Never>?
    private var messageId: Int = 1

    private init() {}

    // MARK: - Public API

    public func subscribe(
        walletAddress: String,
        usdcMint: String,
        rpcEndpoint: String
    ) async throws {
        let wsEndpoint = rpcEndpoint
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")

        Logger.info("Setting up subscription for wallet: \(walletAddress)", category: .balance)

        let tokenAccount = try await deriveATA(wallet: walletAddress, mint: usdcMint, rpcEndpoint: rpcEndpoint)
        currentTokenAccount = tokenAccount

        Logger.debug("Token account: \(tokenAccount)", category: .balance)

        // Connect WebSocket
        guard let url = URL(string: wsEndpoint) else {
            throw SubscriptionError.invalidEndpoint
        }

        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()

        // Subscribe to account changes
        try await subscribeToAccount(tokenAccount)

        // Start listening for messages
        startListening()

        // Fetch initial balance
        try await fetchInitialBalance(tokenAccount: tokenAccount, rpcEndpoint: rpcEndpoint)

        await MainActor.run {
            isSubscribed = true
        }

        Logger.info("Subscribed to balance changes", category: .balance)
    }

    public func unsubscribe() {
        Logger.info("Unsubscribing from balance updates", category: .balance)

        reconnectTask?.cancel()
        reconnectTask = nil

        if let subId = subscriptionId {
            // Send unsubscribe message
            let unsubscribe: [String: Any] = [
                "jsonrpc": "2.0",
                "id": getNextMessageId(),
                "method": "accountUnsubscribe",
                "params": [subId]
            ]

            if let data = try? JSONSerialization.data(withJSONObject: unsubscribe),
               let message = String(data: data, encoding: .utf8) {
                webSocket?.send(.string(message)) { _ in }
            }
        }

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        subscriptionId = nil
        currentTokenAccount = nil

        Task { @MainActor in
            isSubscribed = false
        }
    }

    // MARK: - Private Methods

    private func subscribeToAccount(_ tokenAccount: String) async throws {
        let subscribe: [String: Any] = [
            "jsonrpc": "2.0",
            "id": getNextMessageId(),
            "method": "accountSubscribe",
            "params": [
                tokenAccount,
                [
                    "encoding": "jsonParsed",
                    "commitment": "confirmed"
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: subscribe),
              let message = String(data: data, encoding: .utf8) else {
            throw SubscriptionError.serializationFailed
        }

        try await webSocket?.send(.string(message))

        // Wait for subscription confirmation
        let response = try await webSocket?.receive()

        if case .string(let text) = response,
           let responseData = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let result = json["result"] as? Int {
            subscriptionId = result
            Logger.debug("Subscription ID: \(result)", category: .balance)
        }
    }

    private func startListening() {
        Task {
            while webSocket != nil {
                do {
                    guard let message = try await webSocket?.receive() else { break }

                    switch message {
                    case .string(let text):
                        handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    Logger.error("WebSocket error: \(error)", category: .balance)
                    await handleDisconnect()
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Check if this is a notification (has "method" field)
        guard let method = json["method"] as? String,
              method == "accountNotification" else {
            return
        }

        // Parse the account data
        guard let params = json["params"] as? [String: Any],
              let result = params["result"] as? [String: Any],
              let value = result["value"] as? [String: Any],
              let accountData = value["data"] as? [String: Any],
              let parsed = accountData["parsed"] as? [String: Any],
              let info = parsed["info"] as? [String: Any],
              let tokenAmount = info["tokenAmount"] as? [String: Any],
              let amountString = tokenAmount["amount"] as? String,
              let amount = UInt64(amountString) else {
            Logger.error("Failed to parse account notification", category: .balance)
            return
        }

        let cents = ZeroSettleConstants.USDC.toCents(amount)

        Logger.info("Balance update: \(ZeroSettleConstants.USDC.formatCents(cents))", category: .balance)

        Task { @MainActor in
            self.balanceCents = cents
        }
    }

    private func handleDisconnect() async {
        await MainActor.run {
            isSubscribed = false
        }

        reconnectTask = Task {
            let delayNanoseconds = UInt64(ZeroSettleConstants.Network.websocketReconnectDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            guard !Task.isCancelled,
                  currentTokenAccount != nil else { return }

            Logger.info("Attempting to reconnect...", category: .balance)
        }
    }

    private func fetchInitialBalance(tokenAccount: String, rpcEndpoint: String) async throws {
        guard let url = URL(string: rpcEndpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenAccountBalance",
            "params": [
                tokenAccount,
                ["commitment": "confirmed"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct Response: Decodable {
            struct Result: Decodable {
                struct Value: Decodable {
                    let amount: String
                }
                let value: Value
            }
            let result: Result?
        }

        if let response = try? JSONDecoder().decode(Response.self, from: data),
           let amountStr = response.result?.value.amount,
           let amount = UInt64(amountStr) {
            let cents = ZeroSettleConstants.USDC.toCents(amount)

            await MainActor.run {
                self.balanceCents = cents
            }

            Logger.debug("Initial balance: \(ZeroSettleConstants.USDC.formatCents(cents))", category: .balance)
        }
    }

    private func deriveATA(wallet: String, mint: String, rpcEndpoint: String) async throws -> String {
        guard let url = URL(string: rpcEndpoint) else {
            throw SubscriptionError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenAccountsByOwner",
            "params": [
                wallet,
                ["mint": mint],
                ["encoding": "jsonParsed"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct Response: Decodable {
            struct Result: Decodable {
                struct Account: Decodable {
                    let pubkey: String
                }
                let value: [Account]
            }
            let result: Result?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)

        guard let ata = response.result?.value.first?.pubkey else {
            throw SubscriptionError.ataNotFound
        }

        return ata
    }

    private func getNextMessageId() -> Int {
        messageId += 1
        return messageId
    }

    // MARK: - Errors

    public enum SubscriptionError: Error, LocalizedError {
        case invalidEndpoint
        case serializationFailed
        case ataNotFound
        case connectionFailed

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "Invalid RPC endpoint"
            case .serializationFailed: return "Failed to serialize message"
            case .ataNotFound: return "Token account not found"
            case .connectionFailed: return "WebSocket connection failed"
            }
        }
    }
}
