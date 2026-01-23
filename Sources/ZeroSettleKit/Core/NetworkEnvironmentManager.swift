//
//  NetworkEnvironmentManager.swift
//  ZeroSettleKit
//
//  Manages network environment preference (mainnet/devnet) with UserDefaults persistence
//

import Foundation
import SwiftUI

/// Manages the network environment setting for blockchain operations
@MainActor
public class NetworkEnvironmentManager: ObservableObject {
    public static let shared = NetworkEnvironmentManager()

    private let userDefaultsKey = "zerosettle.networkEnvironment"

    /// Current network environment
    @Published public var currentEnvironment: NetworkEnvironment {
        didSet {
            saveEnvironment()
            print("[NetworkEnvironment] Switched to \(currentEnvironment.displayName)")
        }
    }

    private init() {
        // Load saved preference or default to mainnet
        if let savedValue = UserDefaults.standard.string(forKey: userDefaultsKey),
           let environment = NetworkEnvironment(rawValue: savedValue) {
            self.currentEnvironment = environment
        } else {
            self.currentEnvironment = .mainnet
        }

        print("[NetworkEnvironment] Initialized with \(currentEnvironment.displayName)")
    }

    /// Toggle between mainnet and devnet
    public func toggleEnvironment() {
        switch currentEnvironment {
        case .mainnet:
            currentEnvironment = .devnet
        case .devnet:
            currentEnvironment = .mainnet
        }
    }

    /// Set a specific environment
    public func setEnvironment(_ environment: NetworkEnvironment) {
        currentEnvironment = environment
    }

    /// Save the current environment to UserDefaults
    private func saveEnvironment() {
        UserDefaults.standard.set(currentEnvironment.rawValue, forKey: userDefaultsKey)
    }

    /// Get the RPC endpoint for any blockchain network based on current environment
    /// - Parameter network: The blockchain network to get endpoint for
    /// - Returns: RPC endpoint URL string
    public func getRpcEndpoint(for network: BlockchainNetwork) -> String {
        switch currentEnvironment {
        case .mainnet:
            return getDefaultMainnetEndpoint(for: network)
        case .devnet:
            return getDefaultDevnetEndpoint(for: network)
        }
    }

    /// Get the RPC endpoint for Solana based on current environment
    /// - Returns: Solana RPC endpoint URL string
    public func getSolanaRpcEndpoint() -> String {
        getRpcEndpoint(for: .solana)
    }

    // MARK: - Private Helpers

    /// Get default mainnet RPC endpoint for a network
    private func getDefaultMainnetEndpoint(for network: BlockchainNetwork) -> String {
        switch network {
        case .solana:
            return "https://api.mainnet-beta.solana.com"
        case .ethereum:
            return "https://eth.llamarpc.com"
        case .base:
            return "https://mainnet.base.org"
        case .arbitrum:
            return "https://arb1.arbitrum.io/rpc"
        case .optimism:
            return "https://mainnet.optimism.io"
        case .polygon:
            return "https://polygon-rpc.com"
        }
    }

    /// Get default devnet RPC endpoint for a network
    private func getDefaultDevnetEndpoint(for network: BlockchainNetwork) -> String {
        switch network {
        case .solana:
            return "https://api.devnet.solana.com"
        case .ethereum:
            return "https://eth-goerli.public.blastapi.io" // Testnet
        case .base:
            return "https://goerli.base.org" // Base Goerli testnet
        case .arbitrum:
            return "https://goerli-rollup.arbitrum.io/rpc" // Arbitrum Goerli
        case .optimism:
            return "https://goerli.optimism.io" // Optimism Goerli
        case .polygon:
            return "https://rpc-mumbai.maticvigil.com" // Mumbai testnet
        }
    }
}
