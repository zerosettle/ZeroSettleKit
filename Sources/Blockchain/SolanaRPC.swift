//
//  SolanaRPC.swift
//  ZeroSettleBlockchain
//
//  Solana JSON-RPC client for blockchain interactions.
//

import Foundation
import ZeroSettleCore

// MARK: - RPC Errors

public enum SolanaRPCError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Error)
    case invalidResponse
    case rpcError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid RPC URL"
        case .requestFailed(let error):
            return "RPC request failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid RPC response"
        case .rpcError(let code, let message):
            return "RPC error \(code): \(message)"
        }
    }
}

// MARK: - RPC Response Types

public struct RPCResponse<T: Decodable>: Decodable {
    public let jsonrpc: String
    public let id: Int
    public let result: T?
    public let error: RPCError?

    public struct RPCError: Decodable {
        public let code: Int
        public let message: String
    }
}

public struct BlockhashResult: Decodable {
    public let value: BlockhashValue

    public struct BlockhashValue: Decodable {
        public let blockhash: String
        public let lastValidBlockHeight: UInt64
    }
}

public struct BalanceResult: Decodable {
    public let value: UInt64
}

public struct TokenBalanceResult: Decodable {
    public let value: TokenBalanceValue

    public struct TokenBalanceValue: Decodable {
        public let amount: String
        public let decimals: Int
    }
}

// MARK: - Solana RPC Client

public actor SolanaRPCClient {
    private let rpcURL: URL
    private let session: URLSession

    public init(rpcURL: URL, session: URLSession = .shared) {
        self.rpcURL = rpcURL
        self.session = session
    }

    public init(environment: NetworkEnvironment) {
        self.rpcURL = environment.solanaRpcURL
        self.session = .shared
    }

    // MARK: - Blockhash

    public func getLatestBlockhash() async throws -> String {
        let response: RPCResponse<BlockhashResult> = try await call(
            method: "getLatestBlockhash",
            params: [["commitment": "confirmed"]]
        )

        if let error = response.error {
            throw SolanaRPCError.rpcError(code: error.code, message: error.message)
        }

        guard let result = response.result else {
            throw SolanaRPCError.invalidResponse
        }

        Logger.debug("Got blockhash: \(result.value.blockhash.prefix(12))...", category: .blockchain)
        return result.value.blockhash
    }

    // MARK: - Balance

    public func getBalance(address: String) async throws -> UInt64 {
        let response: RPCResponse<BalanceResult> = try await call(
            method: "getBalance",
            params: [address]
        )

        if let error = response.error {
            throw SolanaRPCError.rpcError(code: error.code, message: error.message)
        }

        return response.result?.value ?? 0
    }

    public func getTokenAccountBalance(tokenAccount: String) async throws -> UInt64 {
        let response: RPCResponse<TokenBalanceResult> = try await call(
            method: "getTokenAccountBalance",
            params: [tokenAccount, ["commitment": "confirmed"]]
        )

        if let error = response.error {
            // Account doesn't exist = 0 balance
            if error.message.contains("could not find account") {
                return 0
            }
            throw SolanaRPCError.rpcError(code: error.code, message: error.message)
        }

        guard let result = response.result,
              let balance = UInt64(result.value.amount) else {
            return 0
        }

        return balance
    }

    // MARK: - Transaction

    public func sendTransaction(_ signedTransactionBase64: String) async throws -> String {
        guard let txData = Data(base64Encoded: signedTransactionBase64) else {
            throw SolanaRPCError.invalidResponse
        }

        let txBase58 = Base58.encode(txData)

        let response: RPCResponse<String> = try await call(
            method: "sendTransaction",
            params: [txBase58, ["encoding": "base58", "skipPreflight": false]]
        )

        if let error = response.error {
            throw SolanaRPCError.rpcError(code: error.code, message: error.message)
        }

        guard let signature = response.result else {
            throw SolanaRPCError.invalidResponse
        }

        Logger.info("Transaction sent: \(signature.prefix(12))...", category: .blockchain)
        return signature
    }

    // MARK: - Private

    private func call<T: Decodable>(method: String, params: [Any]) async throws -> RPCResponse<T> {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(RPCResponse<T>.self, from: data)
    }
}
