//
//  MetaMaskWalletManager.swift
//  ZeroSettleWallets
//
//  MetaMask wallet integration for Solana via MetaMask iOS SDK.
//
//  Reference implementation: Sources/ZeroSettleKit/MetaMask/MetaMaskManager.swift
//

import Foundation
import Combine
import ZeroSettleCore
import metamask_ios_sdk

@MainActor
public final class MetaMaskWalletManager: ObservableObject, WalletManager {

    // MARK: - Published State

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var walletAddress: String?

    public let walletType: WalletType = .metamask

    // MARK: - Private State

    private var sdk: MetaMaskSDK?

    // MARK: - Initialization

    public init() {
        Logger.debug("MetaMaskWalletManager initialized", category: .wallet)
    }

    // MARK: - WalletManager Protocol

    public func connect() async throws {
        Logger.info("Connecting to MetaMask...", category: .wallet)
        // TODO: Implement MetaMask SDK connection
        // See reference: Sources/ZeroSettleKit/MetaMask/MetaMaskManager.swift
        throw WalletError.notInstalled
    }

    public func disconnect() async {
        Logger.info("Disconnecting from MetaMask", category: .wallet)
        sdk = nil
        isConnected = false
        walletAddress = nil
    }

    public func signMessage(_ messageBase64: String) async throws -> String {
        guard isConnected else {
            throw WalletError.connectionFailed(nil)
        }
        // TODO: Implement MetaMask message signing
        throw WalletError.signingFailed(nil)
    }

    public func signTransaction(_ transactionBase64: String) async throws -> String {
        guard isConnected else {
            throw WalletError.connectionFailed(nil)
        }
        // TODO: Implement MetaMask transaction signing
        throw WalletError.signingFailed(nil)
    }

    public func handleDeeplink(_ url: URL) -> Bool {
        // MetaMask SDK handles its own callbacks
        return false
    }
}
