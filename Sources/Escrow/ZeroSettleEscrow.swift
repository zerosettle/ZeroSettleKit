//
//  ZeroSettleEscrow.swift
//  ZeroSettleEscrow
//
//  Main entry point for the ZeroSettle Escrow SDK.
//  Provides skill-based gaming with blockchain escrow.
//

import Foundation
import SwiftUI
import Combine
import ZeroSettleCore
import ZeroSettleAuth
import ZeroSettleBlockchain
import ZeroSettleWallets

// MARK: - Escrow Errors

public enum ZeroSettleEscrowError: Error, LocalizedError {
    case notConfigured
    case notAuthenticated
    case noActiveSession
    case sessionNotReady(currentState: SessionState)
    case insufficientBalance(required: Int, available: Int)
    case invalidConfiguration(String)
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ZeroSettleEscrow is not configured. Call configure() first."
        case .notAuthenticated:
            return "User is not authenticated. Complete authentication first."
        case .noActiveSession:
            return "No active game session."
        case .sessionNotReady(let state):
            return "Session is not ready for this operation. Current state: \(state.rawValue)"
        case .insufficientBalance(let required, let available):
            return "Insufficient balance. Required: \(required) cents, available: \(available) cents."
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .signingFailed(let message):
            return "Signing failed: \(message)"
        }
    }
}

// MARK: - Balance Update Delegate

/// Internal delegate for receiving balance updates from WebSocket subscription.
protocol BalanceUpdateDelegate: AnyObject {
    @MainActor func balanceDidUpdate(_ lamports: UInt64)
    @MainActor func balanceSubscriptionFailed(_ error: Error)
}

// MARK: - ZeroSettle Escrow

/// Main entry point for the ZeroSettle Escrow SDK.
/// Handles authentication, balance management, and game session lifecycle.
@MainActor
public final class ZeroSettleEscrow: ObservableObject {

    // MARK: - Singleton

    public static let shared = ZeroSettleEscrow()

    // MARK: - Published State

    /// Whether the SDK has been configured.
    @Published public private(set) var isConfigured: Bool = false

    /// Whether auth initialization has completed (session restore attempted).
    /// Use this to avoid showing login UI before session restore finishes.
    @Published public private(set) var isAuthInitialized: Bool = false

    /// Whether the user is authenticated.
    @Published public private(set) var isAuthenticated: Bool = false

    /// The authenticated user's ZeroSettle UUID.
    @Published public private(set) var userId: UUID?

    /// The user's Solana wallet address.
    @Published public private(set) var walletAddress: SolanaAddress?

    /// The user's current balance in cents (updated via WebSocket subscription).
    @Published public private(set) var balanceCents: Int = 0

    /// The currently active game session, if any.
    @Published public private(set) var activeSession: GameSession?

    // MARK: - Delegate

    /// Delegate to receive escrow event callbacks.
    public weak var delegate: ZeroSettleEscrowDelegate?

    // MARK: - Private State

    private var config: EscrowConfig?
    private var authManager: AuthenticationManager?
    private var backend: ZeroSettleBackend?
    private var gameAdminBackend: GameAdminBackend?
    private var balanceSubscription: BalanceSubscription?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        Logger.info("ZeroSettleEscrow initialized", category: .escrow)
    }

    // MARK: - Configuration

    /// Configure the SDK. Must be called before any other methods.
    /// - Parameter config: The escrow configuration
    public func configure(_ config: EscrowConfig) {
        self.config = config

        let authConfig = AuthConfig(
            privyAppId: config.privyAppId,
            privyClientId: config.privyClientId
        )
        authManager = AuthenticationManager(config: authConfig)

        let tokenProvider = PrivyTokenProvider(authManager: authManager!)
        backend = ZeroSettleBackend(
            baseURL: config.backendURL,
            partnerAppId: config.partnerAppId,
            tokenProvider: tokenProvider
        )

        isConfigured = true
        Logger.info("ZeroSettleEscrow configured for \(config.environment.rawValue)", category: .escrow)
        setupAuthObserver()
    }

    /// Set the game admin backend for client server integration.
    /// - Parameter backend: The game admin backend implementation
    public func setGameAdminBackend(_ backend: GameAdminBackend) {
        self.gameAdminBackend = backend
        Logger.info("Game admin backend configured", category: .escrow)
    }

    // MARK: - Authentication

    /// Initialize authentication. Call once at app launch.
    /// Restores existing session if available.
    public func initializeAuth() async {
        guard let authManager, let config else {
            Logger.error("Not configured", category: .escrow)
            return
        }

        await authManager.initialize()
        await authManager.restoreSession()

        // If session was restored, sync escrow state
        if authManager.isAuthenticated, let session = authManager.session {
            do {
                let tokenProvider = PrivyTokenProvider(authManager: authManager)
                backend = ZeroSettleBackend(
                    baseURL: config.backendURL,
                    partnerAppId: config.partnerAppId,
                    tokenProvider: tokenProvider
                )

                let wallet = try SolanaAddress(session.walletAddress)
                let zeroSettleUserId = try await backend!.registerUser(walletAddress: wallet)

                userId = zeroSettleUserId
                walletAddress = wallet
                isAuthenticated = true

                // Fetch balance BEFORE notifying delegate (so syncFromEscrow gets correct balance)
                if let cents = try? await fetchBalanceCents() {
                    balanceCents = cents
                    Logger.info("Restored balance: \(cents) cents", category: .escrow)
                }

                Logger.info("Session restored for user: \(zeroSettleUserId)", category: .escrow)
                delegate?.zeroSettleEscrowDidAuthenticate(userId: zeroSettleUserId, walletAddress: wallet)
                delegate?.zeroSettleEscrowDidUpdateBalance(balanceCents)

                // Subscribe to balance updates for real-time changes
                await subscribeToBalance(wallet: wallet, mint: config.tokenMint)

            } catch {
                Logger.error("Failed to restore session state: \(error)", category: .escrow)
                // Session exists in Privy but we couldn't sync with backend
                // User can still try to use the app, auth will be re-attempted on next action
            }
        }

        // Mark auth initialization as complete (regardless of whether user is authenticated)
        isAuthInitialized = true
        Logger.debug("Auth initialization complete, isAuthenticated: \(isAuthenticated)", category: .escrow)
    }

    /// Send OTP code to phone number.
    /// - Parameter phoneNumber: Phone in E.164 format (e.g., "+14155552671")
    public func sendOTP(to phoneNumber: String) async throws {
        guard let authManager else {
            throw ZeroSettleEscrowError.notConfigured
        }

        do {
            try await authManager.sendOTP(to: phoneNumber)
        } catch {
            delegate?.zeroSettleEscrowAuthenticationFailed(operation: "sendOTP", error: error)
            throw error
        }
    }

    /// Verify OTP and complete login.
    /// - Parameters:
    ///   - code: The 6-digit OTP code
    ///   - phoneNumber: Phone in E.164 format
    public func verifyOTP(code: String, phoneNumber: String) async throws {
        guard let authManager, let config else {
            throw ZeroSettleEscrowError.notConfigured
        }

        do {
            let session = try await authManager.verifyOTP(code: code, phoneNumber: phoneNumber)

            let tokenProvider = PrivyTokenProvider(authManager: authManager)
            backend = ZeroSettleBackend(
                baseURL: config.backendURL,
                partnerAppId: config.partnerAppId,
                tokenProvider: tokenProvider
            )

            let wallet = try SolanaAddress(session.walletAddress)
            let zeroSettleUserId = try await backend!.registerUser(walletAddress: wallet)

            userId = zeroSettleUserId
            walletAddress = wallet
            isAuthenticated = true

            delegate?.zeroSettleEscrowDidAuthenticate(userId: zeroSettleUserId, walletAddress: wallet)

            // Fetch balance AFTER wallet is set (so fetchBalanceCents can use it)
            if let cents = try? await fetchBalanceCents() {
                balanceCents = cents
                Logger.info("Initial balance: \(cents) cents", category: .escrow)
            }
            delegate?.zeroSettleEscrowDidUpdateBalance(balanceCents)

            // Subscribe to balance updates via WebSocket for real-time updates
            await subscribeToBalance(wallet: wallet, mint: config.tokenMint)

        } catch {
            delegate?.zeroSettleEscrowAuthenticationFailed(operation: "verifyOTP", error: error)
            throw error
        }
    }

    /// Logout the current user.
    public func logout() async {
        // Unsubscribe from balance updates
        balanceSubscription?.disconnect()
        balanceSubscription = nil

        await authManager?.logout()

        userId = nil
        walletAddress = nil
        balanceCents = 0
        activeSession = nil
        isAuthenticated = false
        backend = nil

        delegate?.zeroSettleEscrowDidLogout()
        Logger.info("User logged out", category: .escrow)
    }

    // MARK: - Balance

    /// Subscribe to real-time balance updates via WebSocket.
    private func subscribeToBalance(wallet: SolanaAddress, mint: SolanaAddress) async {
        guard let config else { return }

        balanceSubscription = BalanceSubscription(
            environment: config.blockchainEnvironment,
            wallet: wallet,
            tokenMint: mint
        )

        balanceSubscription?.delegate = self

        do {
            try await balanceSubscription?.connect()
            Logger.info("Balance subscription active", category: .escrow)
        } catch {
            Logger.error("Failed to subscribe to balance: \(error)", category: .escrow)
            delegate?.zeroSettleEscrowBalanceFetchFailed(error: error)
        }
    }

    /// Manually refresh the balance (triggers a one-time RPC call).
    public func forceRefreshBalance() async {
        do {
            let cents = try await fetchBalanceCents()
            balanceCents = cents
            delegate?.zeroSettleEscrowDidUpdateBalance(cents)
        } catch {
            Logger.error("Failed to refresh balance: \(error)", category: .escrow)
            delegate?.zeroSettleEscrowBalanceFetchFailed(error: error)
        }
    }

    #if DEBUG
    /// Add funds to the balance (DEV MODE ONLY).
    /// This directly adds to the displayed balance without on-chain transactions.
    /// Use this for testing deposit flows without real payments.
    public func addDevFunds(cents: Int) {
        balanceCents += cents
        delegate?.zeroSettleEscrowDidUpdateBalance(balanceCents)
        Logger.info("DEV: Added \(cents) cents. New balance: \(balanceCents) cents", category: .escrow)
    }
    #endif

    // MARK: - Game Sessions

    /// Start a new game session.
    /// - Parameters:
    ///   - gameDefinitionId: The game definition UUID from your dashboard
    ///   - mode: The game mode (single player, duel, tournament)
    ///   - entryFeeCents: Entry fee in cents
    ///   - maxPayoutMultiplier: Maximum payout multiplier
    /// - Returns: The created game session
    @discardableResult
    public func startSession(
        gameDefinitionId: UUID,
        mode: GameMode = .singlePlayer,
        entryFeeCents: Int,
        maxPayoutMultiplier: Double
    ) async throws -> GameSession {
        guard let backend, let authManager, let userId, let walletAddress else {
            throw ZeroSettleEscrowError.notAuthenticated
        }

        if balanceCents < entryFeeCents {
            throw ZeroSettleEscrowError.insufficientBalance(
                required: entryFeeCents,
                available: balanceCents
            )
        }

        let request = SessionCreationRequest(
            gameDefinitionId: gameDefinitionId,
            mode: mode,
            entryFeeCents: entryFeeCents,
            maxPayoutMultiplier: maxPayoutMultiplier
        )

        do {
            // 1. Create session and get player stake transaction
            let result = try await backend.startSession(
                userId: userId,
                walletAddress: walletAddress,
                gameDefinitionId: gameDefinitionId,
                mode: mode,
                entryFeeCents: entryFeeCents,
                maxPayoutMultiplier: maxPayoutMultiplier
            )

            var session = result.session

            // 2. If there's a player stake transaction, sign and submit it
            if let playerStakeTx = result.playerStakeTransaction {
                Logger.info("Signing player stake transaction...", category: .escrow)

                // Sign with Privy wallet (slot 2 = player signature)
                let signedTx = try await authManager.signTransaction(
                    playerStakeTx,
                    signatureSlot: 2
                )

                // Submit to Solana
                Logger.info("Submitting player stake to Solana...", category: .escrow)
                let txSignature = try await submitTransaction(signedTx)

                // Log explorer link
                if let config {
                    let explorerURL = config.blockchainEnvironment.explorerURL(forTransaction: txSignature)
                    Logger.info("Player stake submitted!", category: .escrow)
                    Logger.info("Explorer: \(explorerURL.absoluteString)", category: .escrow)
                } else {
                    Logger.info("Player stake submitted: \(txSignature)", category: .escrow)
                }

                // Wait for confirmation
                Logger.info("Waiting for player stake confirmation...", category: .escrow)
                try await waitForConfirmation(txSignature)
                Logger.info("Player stake confirmed: \(txSignature)", category: .escrow)

                // 3. Notify game admin backend to stake liability
                if let gameAdminBackend {
                    // Convert cents to USDC base units (6 decimals)
                    // 1 USDC = 1,000,000 base units = 100 cents
                    // So 1 cent = 10,000 base units
                    let entryFeeBaseUnits = entryFeeCents * 10_000

                    Logger.info("Notifying game admin to stake...", category: .escrow)
                    Logger.info("  Entry fee: \(entryFeeCents) cents = \(entryFeeBaseUnits) USDC base units ($\(String(format: "%.2f", Double(entryFeeCents) / 100.0)))", category: .escrow)
                    Logger.info("  Max payout multiplier: \(maxPayoutMultiplier)x", category: .escrow)

                    let gameAdminTxSignature = try await gameAdminBackend.onPlayerStaked(
                        sessionId: session.id,
                        gameDefinitionId: extractIntegerId(from: gameDefinitionId),
                        entryFeeLamports: entryFeeBaseUnits,
                        maxPayoutMultiplier: maxPayoutMultiplier,
                        playerWalletAddress: walletAddress.base58
                    )

                    // Wait for game admin stake confirmation
                    if !gameAdminTxSignature.isEmpty {
                        // New mode: WebSocket confirmation for instant notification
                        Logger.info("Game admin stake submitted: \(gameAdminTxSignature)", category: .escrow)
                        Logger.info("Waiting for game admin stake confirmation...", category: .escrow)
                        try await waitForConfirmation(gameAdminTxSignature)
                        Logger.info("Game admin stake confirmed: \(gameAdminTxSignature)", category: .escrow)
                    } else {
                        // Legacy mode: backend doesn't return signature, use delay fallback
                        Logger.info("Waiting for game admin stake (legacy mode)...", category: .escrow)
                        try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s fallback
                        Logger.info("Game admin stake completed (legacy mode)", category: .escrow)
                    }
                }

                session = GameSession(
                    id: session.id,
                    gameDefinitionId: session.gameDefinitionId,
                    mode: session.mode,
                    entryFeeCents: session.entryFeeCents,
                    maxPayoutMultiplier: session.maxPayoutMultiplier,
                    players: session.players,
                    state: .pendingStakes,  // Both have staked, waiting for confirmation
                    createdAt: session.createdAt
                )
            }

            activeSession = session
            delegate?.zeroSettleEscrowDidCreateSession(session)

            Logger.info("Session started: \(session.id)", category: .escrow)
            return session

        } catch {
            delegate?.zeroSettleEscrowSessionCreationFailed(
                request: request,
                error: error,
                canRetry: true
            )
            throw error
        }
    }

    /// Confirm escrow after both player and game admin have staked.
    /// Validates that both stakes are confirmed on-chain.
    /// - Parameter sessionId: The session ID to confirm
    public func confirmEscrow(sessionId: UUID) async throws {
        guard let backend, let userId else {
            throw ZeroSettleEscrowError.notAuthenticated
        }

        guard var currentSession = activeSession, currentSession.id == sessionId else {
            throw ZeroSettleEscrowError.noActiveSession
        }

        let previousState = currentSession.state

        // Stakes were already confirmed via WebSocket in startSession - no artificial delay needed
        Logger.debug("Confirming escrow with backend...", category: .escrow)

        do {
            // Confirm escrow on ZS backend (validates both stakes are on-chain)
            try await backend.confirmEscrow(sessionId: sessionId, userId: userId)

            currentSession = GameSession(
                id: currentSession.id,
                gameDefinitionId: currentSession.gameDefinitionId,
                mode: currentSession.mode,
                entryFeeCents: currentSession.entryFeeCents,
                maxPayoutMultiplier: currentSession.maxPayoutMultiplier,
                players: currentSession.players,
                state: .escrowConfirmed,
                createdAt: currentSession.createdAt
            )

            activeSession = currentSession
            delegate?.zeroSettleEscrowSessionStateChanged(currentSession, from: previousState)
            delegate?.zeroSettleEscrowDidConfirm(session: currentSession)

            Logger.info("Escrow confirmed for session: \(sessionId)", category: .escrow)

        } catch {
            delegate?.zeroSettleEscrowConfirmationFailed(
                sessionId: sessionId,
                error: error,
                canRetry: true
            )
            throw error
        }
    }

    /// Submit game result for settlement.
    /// - Parameters:
    ///   - sessionId: The session to settle
    ///   - playerResults: The final results for each player
    /// - Note: This method first submits the result on-chain via the game admin server,
    ///   then triggers settlement via the Django backend.
    @discardableResult
    public func submitResult(
        sessionId: UUID,
        playerResults: [PlayerResult]
    ) async throws {
        guard let backend, let walletAddress else {
            throw ZeroSettleEscrowError.notAuthenticated
        }

        guard let currentSession = activeSession, currentSession.id == sessionId else {
            throw ZeroSettleEscrowError.noActiveSession
        }

        // Get the player's result (for single player, there's only one)
        guard let playerResult = playerResults.first else {
            throw ZeroSettleEscrowError.invalidConfiguration("No player results provided")
        }

        do {
            // Step 1: Submit result on-chain via game admin server
            // This sets the session status to allow settlement
            if let gameAdminBackend, let config {
                Logger.info("Submitting game result on-chain...", category: .escrow)
                Logger.info("  Final multiplier: \(playerResult.finalMultiplier)x (\(playerResult.multiplierBps) bps)", category: .escrow)

                try await gameAdminBackend.submitResult(
                    sessionId: sessionId,
                    finalMultiplierBps: playerResult.multiplierBps,
                    playerWalletAddress: walletAddress.base58
                )
                Logger.info("Game result submitted on-chain", category: .escrow)

                // Wait for blockchain finality
                try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds
            }

            // Step 2: Trigger settlement via Django backend
            Logger.info("Triggering settlement...", category: .escrow)
            let response = try await backend.settleSession(sessionId: sessionId)

            if !response.success {
                throw ZeroSettleEscrowError.invalidConfiguration(response.message ?? "Settlement failed")
            }

            // Log explorer link for settlement transaction
            if let txSignature = response.txSignature, let config {
                let explorerURL = config.blockchainEnvironment.explorerURL(forTransaction: txSignature)
                Logger.info("Session settled!", category: .escrow)
                Logger.info("Explorer: \(explorerURL.absoluteString)", category: .escrow)
            } else {
                Logger.info("Session settled: \(sessionId)", category: .escrow)
            }

            let previousState = currentSession.state
            let settledSession = GameSession(
                id: currentSession.id,
                gameDefinitionId: currentSession.gameDefinitionId,
                mode: currentSession.mode,
                entryFeeCents: currentSession.entryFeeCents,
                maxPayoutMultiplier: currentSession.maxPayoutMultiplier,
                players: currentSession.players,
                state: .settled,
                createdAt: currentSession.createdAt
            )
            activeSession = settledSession
            delegate?.zeroSettleEscrowSessionStateChanged(settledSession, from: previousState)

            Logger.info("Settlement complete", category: .escrow)

        } catch {
            delegate?.zeroSettleEscrowSettlementFailed(
                sessionId: sessionId,
                error: error,
                canRetry: true
            )
            throw error
        }
    }

    /// Clear the active session.
    public func clearActiveSession() {
        activeSession = nil
    }

    // MARK: - Game Configuration

    /// Get a game definition by name, including its payout table.
    /// - Parameter name: The game name (e.g., "Wordle")
    /// - Returns: The game definition with payout configuration
    public func getGameDefinition(name: String) async throws -> GameDefinition {
        guard let backend else {
            throw ZeroSettleEscrowError.notConfigured
        }

        return try await backend.getGameDefinition(name: name)
    }

    // MARK: - Signing (for H2H atomic transactions)

    /// Sign a partial transaction for H2H atomic staking.
    /// The transaction is expected to be base64-encoded.
    /// - Parameter transactionBase64: The base64-encoded partial transaction
    /// - Returns: The 64-byte signature in base64 format
    public func signPartialTransaction(_ transactionBase64: String) async throws -> String {
        guard let authManager else {
            throw ZeroSettleEscrowError.notAuthenticated
        }

        // Sign the transaction (this inserts our signature at slot 2)
        let signedTxBase64 = try await authManager.signTransaction(transactionBase64, signatureSlot: 2)

        // Extract just our signature from the signed transaction
        // Transaction format: [num_sigs (1 byte)][sig1 (64 bytes)][sig2 (64 bytes)]...
        guard let signedTxData = Data(base64Encoded: signedTxBase64) else {
            throw ZeroSettleEscrowError.signingFailed("Failed to decode signed transaction")
        }

        // Our signature is at slot 2: byte 1 + 64 bytes (slot 1) = byte 65
        let signatureStart = 1 + 64  // Skip num_sigs byte and first signature
        let signatureEnd = signatureStart + 64

        guard signedTxData.count >= signatureEnd else {
            throw ZeroSettleEscrowError.signingFailed("Transaction too small to contain signature")
        }

        let signature = signedTxData[signatureStart..<signatureEnd]
        return signature.base64EncodedString()
    }

    /// Sign a transaction and submit it to Solana.
    /// Used for user-initiated transactions like token burns.
    /// - Parameters:
    ///   - transactionBase64: Base64-encoded transaction (partially signed by fee payer)
    ///   - signatureSlot: Slot to insert user signature (default 2)
    /// - Returns: Transaction signature
    public func signAndSubmitTransaction(_ transactionBase64: String, signatureSlot: Int = 2) async throws -> String {
        guard let authManager else {
            throw ZeroSettleEscrowError.notAuthenticated
        }

        // Sign the transaction
        let signedTxBase64 = try await authManager.signTransaction(transactionBase64, signatureSlot: signatureSlot)

        // Submit to Solana
        let txSignature = try await submitTransaction(signedTxBase64)

        Logger.info("Transaction submitted: \(txSignature)", category: .escrow)

        return txSignature
    }

    // MARK: - JWT Token (for game server API authentication)

    /// Get the current Django session token for authenticating with game server APIs.
    /// This is the token obtained from `auth/privy-login/` after Privy authentication.
    /// - Returns: The Django session token, or nil if not authenticated
    public func getAccessToken() async -> String? {
        // Return the Django session token, not the raw Privy access token
        // The Django backend issues this token after validating the Privy JWT
        guard let token = backend?.sessionToken else {
            Logger.debug("getAccessToken: No Django session token (backend: \(backend != nil), isAuthenticated: \(isAuthenticated))", category: .auth)
            return nil
        }
        Logger.debug("getAccessToken: Got Django session token (length: \(token.count))", category: .auth)
        return token
    }

    /// Get the raw Privy access token (for Privy-specific operations).
    /// Most API calls should use `getAccessToken()` which returns the Django session token.
    /// - Returns: The Privy JWT token, or nil if not authenticated
    public func getPrivyAccessToken() async -> String? {
        guard let authManager else {
            Logger.debug("getPrivyAccessToken: authManager is nil", category: .auth)
            return nil
        }
        return await authManager.getAccessToken()
    }

    // MARK: - Private Helpers

    private func setupAuthObserver() {
        authManager?.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuth in
                if !isAuth && self?.isAuthenticated == true {
                    // User was logged out
                    Task { @MainActor in
                        await self?.logout()
                    }
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Balance Update Delegate

extension ZeroSettleEscrow: BalanceUpdateDelegate {
    nonisolated func balanceDidUpdate(_ lamports: UInt64) {
        Task { @MainActor in
            // Convert USDC (6 decimals) to cents
            // 1 USDC = 1,000,000 lamports = 100 cents
            let cents = Int(lamports / 10_000)

            // Only update if changed
            if self.balanceCents != cents {
                self.objectWillChange.send()
                self.balanceCents = cents
                self.delegate?.zeroSettleEscrowDidUpdateBalance(cents)
            }
        }
    }

    nonisolated func balanceSubscriptionFailed(_ error: Error) {
        Task { @MainActor in
            Logger.error("Balance subscription failed: \(error)", category: .escrow)
            self.delegate?.zeroSettleEscrowBalanceFetchFailed(error: error)
        }
    }

    // MARK: - Balance Fetching

    /// Fetch USDC balance in cents using RPC.
    private func fetchBalanceCents() async throws -> Int {
        guard let wallet = walletAddress, let config else {
            throw ZeroSettleEscrowError.notAuthenticated
        }

        // Get RPC URL and USDC mint from config (uses blockchainEnvironment)
        let rpcURL = config.solanaRpcURL
        let usdcMint = config.tokenMint.base58

        Logger.debug("Fetching balance from \(config.blockchainEnvironment.displayName) (\(rpcURL))", category: .balance)
        Logger.debug("Wallet address: \(wallet.base58)", category: .balance)

        // Derive ATA using PDADerivation from Blockchain module
        let ataAddress = try PDADerivation.deriveATA(wallet: wallet.base58, mint: usdcMint)
        Logger.debug("Derived ATA: \(ataAddress)", category: .balance)

        let balance = try await fetchTokenAccountBalance(tokenAccount: ataAddress, rpcURL: rpcURL)

        // USDC has 6 decimals, convert to cents (divide by 10,000)
        let cents = Int(balance / 10_000)
        Logger.info("USDC balance: $\(String(format: "%.2f", Double(cents) / 100.0)) (\(config.environment.displayName))", category: .balance)

        return cents
    }

    private func fetchTokenAccountBalance(tokenAccount: String, rpcURL: URL) async throws -> UInt64 {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenAccountBalance",
            "params": [tokenAccount]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TokenBalanceResponse: Decodable {
            struct Result: Decodable {
                struct Value: Decodable {
                    let amount: String
                }
                let value: Value?
            }
            struct RPCError: Decodable {
                let message: String
            }
            let result: Result?
            let error: RPCError?
        }

        let decoded = try JSONDecoder().decode(TokenBalanceResponse.self, from: data)

        // If account doesn't exist, return 0
        if decoded.error != nil {
            return 0
        }

        guard let amountString = decoded.result?.value?.amount,
              let amount = UInt64(amountString) else {
            return 0
        }

        return amount
    }

    // MARK: - Transaction Submission

    /// Submit a signed transaction to Solana RPC.
    /// - Parameter signedTxBase64: Base64-encoded signed transaction
    /// - Returns: Transaction signature
    private func submitTransaction(_ signedTxBase64: String) async throws -> String {
        guard let config else { throw ZeroSettleEscrowError.notConfigured }

        var request = URLRequest(url: config.solanaRpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sendTransaction",
            "params": [signedTxBase64, ["encoding": "base64"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct SendTxResponse: Decodable {
            let result: String?
            let error: RPCError?

            struct RPCError: Decodable {
                let message: String
            }
        }

        let response = try JSONDecoder().decode(SendTxResponse.self, from: data)

        if let error = response.error {
            throw ZeroSettleEscrowError.invalidConfiguration("RPC error: \(error.message)")
        }

        guard let signature = response.result else {
            throw ZeroSettleEscrowError.invalidConfiguration("No transaction signature returned")
        }

        return signature
    }

    /// Wait for a transaction to be confirmed on-chain using WebSocket subscription.
    /// Uses Solana's `signatureSubscribe` for instant notification instead of polling.
    /// - Parameter signature: Transaction signature to wait for
    private func waitForConfirmation(_ signature: String) async throws {
        guard let config else { throw ZeroSettleEscrowError.notConfigured }

        Logger.debug("Subscribing to signature confirmation: \(signature)", category: .escrow)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let wsURL = config.solanaWebSocketURL
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: wsURL)

            var didResume = false
            let lock = NSLock()

            func safeResume(with result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // Set up timeout task
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 30_000_000_000)  // 30 second timeout
                safeResume(with: .failure(ZeroSettleEscrowError.invalidConfiguration("Transaction confirmation timeout")))
            }

            task.resume()

            // Subscribe to signature updates
            let subscribeMessage: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "signatureSubscribe",
                "params": [
                    signature,
                    ["commitment": "confirmed"]
                ]
            ]

            guard let messageData = try? JSONSerialization.data(withJSONObject: subscribeMessage),
                  let messageString = String(data: messageData, encoding: .utf8) else {
                timeoutTask.cancel()
                safeResume(with: .failure(ZeroSettleEscrowError.invalidConfiguration("Failed to create subscription message")))
                return
            }

            let message = URLSessionWebSocketTask.Message.string(messageString)

            task.send(message) { error in
                if let error = error {
                    timeoutTask.cancel()
                    safeResume(with: .failure(error))
                    return
                }
            }

            // Listen for confirmation notification
            func receiveMessage() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        if case .string(let text) = message,
                           let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                            // Check for subscription confirmation (id: 1)
                            if json["id"] as? Int == 1 {
                                // Subscription confirmed, keep listening
                                Logger.debug("Signature subscription confirmed", category: .escrow)
                                receiveMessage()
                                return
                            }

                            // Check for signature notification
                            if let params = json["params"] as? [String: Any],
                               let result = params["result"] as? [String: Any],
                               let value = result["value"] as? [String: Any] {

                                timeoutTask.cancel()

                                // Check for error in transaction
                                if let err = value["err"], !(err is NSNull) {
                                    Logger.error("Transaction failed: \(err)", category: .escrow)
                                    safeResume(with: .failure(ZeroSettleEscrowError.invalidConfiguration("Transaction failed: \(err)")))
                                } else {
                                    Logger.info("Transaction confirmed via WebSocket", category: .escrow)
                                    safeResume(with: .success(()))
                                }
                                return
                            }
                        }
                        receiveMessage()

                    case .failure(let error):
                        timeoutTask.cancel()
                        safeResume(with: .failure(error))
                    }
                }
            }

            receiveMessage()
        }
    }

    /// Extract integer ID from our UUID format.
    /// Our format: 00000000-0000-0000-0000-{12-digit padded ID}
    private func extractIntegerId(from uuid: UUID) -> Int {
        let uuidString = uuid.uuidString
        let suffix = String(uuidString.suffix(12))
        return Int(suffix) ?? 0
    }
}

// MARK: - Privy Token Provider

/// Adapts AuthenticationManager to provide JWT tokens for backend auth.
private final class PrivyTokenProvider: JWTTokenProvider, @unchecked Sendable {
    private let authManager: AuthenticationManager

    init(authManager: AuthenticationManager) {
        self.authManager = authManager
    }

    func getAccessToken() async -> String? {
        let token = await authManager.getAccessToken()
        if token == nil {
            Logger.debug("PrivyTokenProvider: No access token available (isAuthenticated: \(await authManager.isAuthenticated))", category: .auth)
        }
        return token
    }
}
