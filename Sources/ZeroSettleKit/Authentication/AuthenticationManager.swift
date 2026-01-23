import Foundation
import Combine
import PrivySDK
import Solana

/// Manages Privy authentication and wallet operations
public final class AuthenticationManager: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var currentUser: PrivyUser?
    @Published public private(set) var walletAddress: String?
    @Published public private(set) var solanaBalance: Decimal = 0

    // MARK: - Public Properties

    public weak var delegate: ZeroSettleDelegate?

    // MARK: - Private Properties

    private let config: ZeroSettleConfig
    private var privy: Privy?
    private let LAMPORTS_PER_SOL: Decimal = 1_000_000_000

#if DEBUG
    private let logLevel: PrivyLogLevel = .verbose
#else
    private let logLevel: PrivyLogLevel = .none
#endif

    // MARK: - Initialization

    public init(config: ZeroSettleConfig) {
        self.config = config
        Logger.info("AuthenticationManager initialized", category: .auth)
    }

    // MARK: - Initialization Methods

    /// Fast initialization - only create Privy SDK, defer everything else
    /// This should complete in 2-3 seconds for fast app launch
    public func initializeFast() async {
        let alreadyInitialized = await MainActor.run { self.isInitialized }
        guard !alreadyInitialized else {
            Logger.debug("Privy already initialized", category: .auth)
            return
        }

        Logger.info("[Fast Init] Initializing Privy SDK (minimal)...", category: .auth)

        // Only initialize the Privy SDK - no auth checks, no balance fetching
        let privyInstance = await MainActor.run { () -> Privy in
            let privyConfig = PrivyConfig(
                appId: config.privyAppId,
                appClientId: config.privyClientId,
                loggingConfig: .init(logLevel: logLevel)
            )
            return PrivySdk.initialize(config: privyConfig)
        }

        await MainActor.run {
            self.privy = privyInstance
            self.isInitialized = true
            Logger.info("[Fast Init] Privy SDK ready - auth check skipped", category: .auth)
        }

        // NOTE: We intentionally skip auto auth restore to avoid UI stalls.
        // Apps can call checkAndRestoreSession() manually if they want restore behavior.
    }

    /// Check and restore existing session (call manually if you want auto-restore)
    public func checkAndRestoreSession() async {
        guard let privy = await MainActor.run(body: { self.privy }) else {
            Logger.debug("[Deferred] Privy not initialized", category: .auth)
            return
        }

        // Check auth state
        let authState = await privy.getAuthState()

        switch authState {
        case .authenticated(let user):
            Logger.info("[Deferred] User authenticated: \(user.id)", category: .auth)

            let walletAddr = user.embeddedSolanaWallets.first?.address

            await MainActor.run {
                self.isAuthenticated = true
                self.currentUser = user
                self.walletAddress = walletAddr
                Logger.info("[Deferred] Auth state restored (balance fetch skipped)", category: .auth)
            }

            // Note: Balance fetching removed from fast init
            // Apps can call getCentsBalance() or fetch balance manually when needed

            // Notify delegate
            await MainActor.run {
                if let address = walletAddr {
                    let walletInfo = WalletInfo(
                        address: address,
                        network: .solana,
                        isNew: false,
                        type: "privy_embedded"
                    )
                    self.delegate?.didAuthenticate(userId: user.id, wallet: walletInfo)
                }
            }

        case .unauthenticated:
            Logger.info("[Deferred] User not authenticated", category: .auth)
            await MainActor.run {
                self.isAuthenticated = false
                self.currentUser = nil
                self.walletAddress = nil
            }

        case .notReady, .authenticatedUnverified:
            Logger.debug("[Deferred] Privy not ready or can't verify", category: .auth)
            await MainActor.run {
                self.isAuthenticated = false
            }
        }
    }

    /// Initialize Privy completely in background, only update UI on main thread when ready
    /// NOTE: This is the old slow method - use initializeFast() for app launch
    public func initializeInBackground() async {
        let alreadyInitialized = await MainActor.run { self.isInitialized }
        guard !alreadyInitialized else {
            Logger.debug("Privy already initialized", category: .auth)
            return
        }

        Logger.info("[Background] Initializing Privy SDK...", category: .auth)

        // Initialize Privy SDK (must be on main actor)
        let privyInstance = await MainActor.run { () -> Privy in
            let privyConfig = PrivyConfig(
                appId: config.privyAppId,
                appClientId: config.privyClientId,
                loggingConfig: .init(logLevel: logLevel)
            )
            return PrivySdk.initialize(config: privyConfig)
        }

        Logger.debug("[Background] Privy instance created, checking auth state...", category: .auth)

        // Check auth state in background
        let authState = await privyInstance.getAuthState()

        switch authState {
        case .authenticated(let user):
            Logger.info("[Background] User authenticated: \(user.id)", category: .auth)

            // Get active wallet address using centralized helper
            let walletAddr = getActiveWalletAddress(for: user)

            // Fetch balance in background
            var balance: Decimal = 0
            if walletAddr != nil {
                Logger.debug("[Background] Fetching Solana balance...", category: .balance)
                do {
                    // Use nil to let fetchCurrentUsersSolBalance use NetworkEnvironmentManager
                    balance = try await fetchCurrentUsersSolBalance(privy: privyInstance, rpcURL: nil)
                    Logger.debug("[Background] Balance fetched: \(balance) SOL", category: .balance)
                } catch {
                    Logger.error("[Background] Could not fetch balance: \(error)", category: .balance)
                }
            }

            await MainActor.run {
                self.privy = privyInstance
                self.isInitialized = true
                self.isAuthenticated = true
                self.currentUser = user
                self.walletAddress = walletAddr
                self.solanaBalance = balance
                Logger.info("[Main Thread] UI updated - user authenticated", category: .auth)

                if let address = walletAddr {
                    let walletInfo = WalletInfo(
                        address: address,
                        network: .solana,
                        isNew: false,
                        type: "privy_embedded"
                    )
                    self.delegate?.didAuthenticate(userId: user.id, wallet: walletInfo)
                }
            }

        case .unauthenticated:
            Logger.info("[Background] User not authenticated", category: .auth)

            await MainActor.run {
                self.privy = privyInstance
                self.isInitialized = true
                self.isAuthenticated = false
                self.currentUser = nil
                self.walletAddress = nil
                Logger.info("[Main Thread] UI updated - user not authenticated", category: .auth)
            }

        case .notReady, .authenticatedUnverified:
            Logger.debug("[Background] Privy not ready or can't verify", category: .auth)

            await MainActor.run {
                self.privy = privyInstance
                self.isInitialized = true
                self.isAuthenticated = false
                Logger.info("[Main Thread] UI updated - not ready", category: .auth)
            }
        }
    }

    /// Call this to initialize Privy SDK (synchronous version)
    /// Note: Must run on MainActor as Privy may present web views
    @MainActor
    public func initialize() {
        guard !isInitialized else {
            Logger.debug("Privy already initialized", category: .auth)
            return
        }

        Logger.info("Initializing Privy SDK...", category: .auth)

        let privyConfig = PrivyConfig(
            appId: config.privyAppId,
            appClientId: config.privyClientId,
            loggingConfig: .init(logLevel: logLevel)
        )

        let privyInstance = PrivySdk.initialize(config: privyConfig)

        self.privy = privyInstance
        self.isInitialized = true

        // Try to check auth immediately with cached data
        if let user = privyInstance.user {
            self.isAuthenticated = true
            self.currentUser = user

            // Get active wallet address using centralized helper
            self.walletAddress = getActiveWalletAddress(for: user)

            Logger.info("User already authenticated (cached): \(user.id)", category: .auth)
        }

        Logger.info("Privy initialized successfully", category: .auth)

        Task {
            await self.checkAuthState()
        }
    }

    // MARK: - Authentication State

    /// Check the user's current authentication state
    @MainActor
    public func checkAuthState() async {
        guard let privy = privy else {
            Logger.debug("Privy not initialized yet", category: .auth)
            return
        }

        Logger.debug("Checking auth state...", category: .auth)

        let authState = await privy.getAuthState()

        switch authState {
        case .authenticated(let user):
            self.isAuthenticated = true
            self.currentUser = user

            // Get active wallet address using centralized helper
            self.walletAddress = getActiveWalletAddress(for: user)

            Logger.info("User authenticated: \(user.id)", category: .auth)

        case .notReady:
            Logger.debug("Privy not ready - treating as not authenticated", category: .auth)
            self.isAuthenticated = false

        case .authenticatedUnverified:
            Logger.debug("Cannot verify auth - treating as not authenticated", category: .auth)
            self.isAuthenticated = false

        case .unauthenticated:
            self.isAuthenticated = false
            self.currentUser = nil
            self.walletAddress = nil
            Logger.info("User not authenticated", category: .auth)
        }
    }

    /// Check if a user is currently cached inside Privy
    public func hasAuthenticatedUser() async -> Bool {
        await MainActor.run {
            self.privy?.user != nil
        }
    }

    /// Get the Privy user information for backend authentication
    /// Returns the user's DID (Privy user ID) which can be used to authenticate with your backend
    /// - Parameter phoneNumber: The phone number used for authentication (from OTP login)
    /// - Returns: A tuple containing (userId: String, walletAddress: String?)
    @MainActor
    public func getPrivyUserInfo(phoneNumber: String) async throws -> (userId: String, walletAddress: String?) {
        guard privy != nil else {
            throw AuthenticationError.notInitialized
        }

        guard isAuthenticated, let user = currentUser else {
            throw AuthenticationError.notAuthenticated
        }

        Logger.debug("Got Privy user info - User ID: \(user.id), Phone: \(phoneNumber), Wallet: \(walletAddress ?? "N/A")", category: .auth)

        return (userId: user.id, walletAddress: walletAddress)
    }

    // MARK: - SMS Authentication

    /// Step 1: Send OTP code to phone number
    /// - Parameter phoneNumber: Phone number in E.164 format (e.g., "+14155552671")
    public func sendOTPCode(to phoneNumber: String) async throws {
        guard let privy = await MainActor.run(body: { self.privy }) else {
            throw AuthenticationError.notInitialized
        }

        do {
            try await privy.sms.sendCode(to: phoneNumber)
            Logger.info("OTP sent to \(phoneNumber)", category: .auth)
        } catch {
            Logger.error("Error sending OTP: \(error)", category: .auth)
            throw AuthenticationError.otpSendFailed(error)
        }
    }

    /// Step 2: Verify OTP and login
    /// - Parameters:
    ///   - code: The 6-digit OTP code
    ///   - phoneNumber: Phone number in E.164 format
    @MainActor
    public func loginWithOTP(code: String, phoneNumber: String) async throws {
        guard let privy = privy else {
            throw AuthenticationError.notInitialized
        }

        do {
            Logger.info("[Main Thread] Logging in with OTP...", category: .auth)
            let user = try await privy.sms.loginWithCode(code, sentTo: phoneNumber)

            Logger.info("[Main Thread] Login successful, processing in background...", category: .auth)

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                var walletAddr: String?
                var balance: Decimal = 0
                var isNewWallet = false

                if user.embeddedSolanaWallets.isEmpty {
                    Logger.info("[Background] No Solana wallet found, creating...", category: .wallet)
                    do {
                        let wallet = try await user.createSolanaWallet(allowAdditional: false)
                        walletAddr = wallet.address
                        isNewWallet = true
                        // Save as active wallet
                        await MainActor.run {
                            self.saveActiveWalletAddress(wallet.address)
                        }
                        Logger.info("[Background] Created new Solana wallet: \(wallet.address)", category: .wallet)
                    } catch {
                        Logger.error("[Background] Could not create Solana wallet: \(error)", category: .wallet)
                    }
                } else {
                    // Get active wallet address using centralized helper
                    walletAddr = await MainActor.run {
                        self.getActiveWalletAddress(for: user)
                    }
                    Logger.debug("[Background] Using existing Solana wallet: \(walletAddr ?? "")", category: .wallet)
                }

                await MainActor.run {
                    self.isAuthenticated = true
                    self.currentUser = user
                    self.walletAddress = walletAddr
                    self.solanaBalance = balance
                    Logger.info("[Main Thread] Login complete, UI updated", category: .auth)

                    if let address = walletAddr {
                        let walletInfo = WalletInfo(
                            address: address,
                            network: .solana,
                            isNew: isNewWallet,
                            type: "privy_embedded"
                        )
                        self.delegate?.didAuthenticate(userId: user.id, wallet: walletInfo)
                    }
                }
            }

        } catch {
            Logger.error("Error logging in: \(error)", category: .auth)
            throw AuthenticationError.authenticationFailed(error)
        }
    }

    // MARK: - Embedded Wallet

    /// Create an embedded Solana wallet for the authenticated user
    @MainActor
    public func createSolanaWallet(allowAdditional: Bool = false) async throws -> EmbeddedSolanaWallet {
        guard let user = currentUser else {
            throw AuthenticationError.notAuthenticated
        }

        do {
            let wallet = try await user.createSolanaWallet(allowAdditional: allowAdditional)
            self.walletAddress = wallet.address
            // Save as the active wallet so it persists on app restart
            saveActiveWalletAddress(wallet.address)
            Logger.info("Created Solana wallet with address: \(wallet.address)", category: .wallet)
            return wallet
        } catch {
            Logger.error("Error creating Solana wallet: \(error)", category: .wallet)
            throw AuthenticationError.walletError(error)
        }
    }

    /// Get the user's embedded Solana wallets
    public func getSolanaWallets() -> [EmbeddedSolanaWallet] {
        currentUser?.embeddedSolanaWallets ?? []
    }

    /// Sign a message with the user's Solana wallet
    public func signMessage(_ message: String) async throws -> String {
        guard let user = await MainActor.run(body: { self.currentUser }) else {
            throw AuthenticationError.notAuthenticated
        }

        // Use the active wallet address, not just .first
        guard let activeWalletAddress = await MainActor.run(body: { self.walletAddress }),
              let wallet = user.embeddedSolanaWallets.first(where: { $0.address == activeWalletAddress }) else {
            throw AuthenticationError.noWalletFound
        }

        do {
            let messageData = message.data(using: .utf8) ?? Data()
            let base64Message = messageData.base64EncodedString()

            let signature = try await wallet.provider.signMessage(message: base64Message)
            Logger.debug("Signed message successfully", category: .signing)
            return signature
        } catch {
            Logger.error("Error signing message: \(error)", category: .signing)
            throw AuthenticationError.walletError(error)
        }
    }

    /// Sign base64-encoded message bytes and return base58 signature
    /// Used for atomic Solana transactions where server builds the tx
    /// - Parameter messageBase64: Base64-encoded Solana message bytes
    /// - Returns: Base58-encoded signature
    public func signMessageBase64(_ messageBase64: String) async throws -> String {
        guard let user = await MainActor.run(body: { self.currentUser }) else {
            throw AuthenticationError.notAuthenticated
        }

        guard let activeWalletAddress = await MainActor.run(body: { self.walletAddress }),
              let wallet = user.embeddedSolanaWallets.first(where: { $0.address == activeWalletAddress }) else {
            throw AuthenticationError.noWalletFound
        }

        do {
            Logger.debug("Signing message bytes with wallet: \(wallet.address)", category: .signing)

            // Privy's signMessage expects base64-encoded data
            let signatureString = try await wallet.provider.signMessage(message: messageBase64)

            // Privy returns signature, we need to convert to base58
            // Try decoding as base64 first (Privy usually returns base64)
            if let signatureData = Data(base64Encoded: signatureString) {
                let base58Signature = Base58.encode(Array(signatureData))
                Logger.debug("Message signed (base58)", category: .signing)
                return base58Signature
            } else {
                // Already base58 or another format - return as-is
                Logger.debug("Message signed (raw format)", category: .signing)
                return signatureString
            }
        } catch {
            Logger.error("Error signing message: \(error)", category: .signing)
            throw AuthenticationError.walletError(error)
        }
    }

    /// Sign a partial transaction and return just the signature (base58)
    /// Used for atomic staking where server collects signatures from multiple parties
    /// - Parameter partialTxBase64: Base64-encoded partial transaction
    /// - Returns: Base58-encoded signature for this wallet's portion
    public func signPartialTransaction(_ partialTxBase64: String) async throws -> String {
        guard let user = await MainActor.run(body: { self.currentUser }) else {
            throw AuthenticationError.notAuthenticated
        }

        guard let activeWalletAddress = await MainActor.run(body: { self.walletAddress }),
              let wallet = user.embeddedSolanaWallets.first(where: { $0.address == activeWalletAddress }) else {
            throw AuthenticationError.noWalletFound
        }

        do {
            Logger.debug("Signing partial transaction with wallet: \(wallet.address)", category: .signing)

            // Decode the transaction from base64
            guard let txBytes = Data(base64Encoded: partialTxBase64) else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 transaction"]))
            }

            // Extract the MESSAGE portion from the transaction (same as signTransactionBase64)
            // Solana transaction format: [num_sigs][sig1][sig2]...[MESSAGE]
            let numSigs = Int(txBytes[0])
            let messageStart = 1 + (numSigs * 64)

            guard txBytes.count > messageStart else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transaction too small to extract message (need > \(messageStart) bytes, have \(txBytes.count))"]))
            }

            let messageBytes = txBytes[messageStart...]
            let messageBase64 = messageBytes.base64EncodedString()

            Logger.debug("Extracted message: \(messageBytes.count) bytes from \(numSigs)-sig tx", category: .signing)

            // Sign the MESSAGE (not the full transaction) - this is what Privy expects
            let signatureString = try await wallet.provider.signMessage(message: messageBase64)

            // Decode the signature - Privy may return base64 OR base58
            var signatureData: Data?

            if let base64Decoded = Data(base64Encoded: signatureString) {
                signatureData = base64Decoded
            } else if let base58Decoded = Base58.decode(signatureString) {
                signatureData = Data(base58Decoded)
            }

            guard let finalSignature = signatureData, finalSignature.count == 64 else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to decode signature or wrong size (tried base64 and base58)"]))
            }

            Logger.debug("Partial transaction signed successfully", category: .signing)

            // Always return base64 (backend expects base64)
            return finalSignature.base64EncodedString()
        } catch {
            Logger.error("Error signing partial transaction: \(error)", category: .signing)
            throw AuthenticationError.walletError(error)
        }
    }

    /// Sign a Solana transaction with the user's Privy embedded wallet
    /// - Parameter serializedTransaction: Base58-encoded unsigned transaction
    /// - Returns: Base58-encoded signed transaction, ready to be submitted to the network
    public func signTransaction(_ serializedTransaction: String) async throws -> String {
        guard let user = await MainActor.run(body: { self.currentUser }) else {
            throw AuthenticationError.notAuthenticated
        }

        // Use the active wallet address, not just .first
        guard let activeWalletAddress = await MainActor.run(body: { self.walletAddress }),
              let wallet = user.embeddedSolanaWallets.first(where: { $0.address == activeWalletAddress }) else {
            throw AuthenticationError.noWalletFound
        }

        do {
            Logger.debug("Signing transaction with wallet: \(wallet.address)", category: .signing)

            // Privy's signMessage method for Solana transactions returns the signature
            // We need to combine it with the transaction to get a fully signed transaction
            let signatureString = try await wallet.provider.signMessage(message: serializedTransaction)

            // Decode the unsigned transaction
            guard let unsignedTxBytes = Base58.decode(serializedTransaction) else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode unsigned transaction"]))
            }

            // Privy returns signature as base64, decode it
            var signatureBytes: Data?

            if let base64Decoded = Data(base64Encoded: signatureString) {
                signatureBytes = base64Decoded
            } else if let base58Decoded = Base58.decode(signatureString) {
                signatureBytes = Data(base58Decoded)
            }

            guard let signature = signatureBytes else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode signature (tried both base64 and base58)"]))
            }

            // Combine signature with transaction
            // Solana transaction format: [num_signatures][signature_1]...[signature_n][message]
            // Our transaction already has an empty signature slot, we need to replace it
            var signedTxBytes = unsignedTxBytes

            // Replace the empty signature (bytes 1-64) with the actual signature
            if signedTxBytes.count >= 65 && signature.count >= 64 {
                signedTxBytes.replaceSubrange(1...64, with: signature.prefix(64))
            } else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid transaction structure (tx: \(signedTxBytes.count) bytes, sig: \(signature.count) bytes)"]))
            }

            // Encode back to base58
            let signedTransaction = Base58.encode(signedTxBytes)

            Logger.debug("Transaction signed: \(signedTxBytes.count) bytes", category: .signing)

            return signedTransaction

        } catch {
            Logger.error("Error signing Solana transaction: \(error)", category: .signing)
            throw AuthenticationError.walletError(error)
        }
    }

    /// Sign a Solana transaction (base64 format)
    /// - Parameters:
    ///   - transactionBase64: Base64-encoded partially-signed transaction
    ///   - signatureSlot: Which signature slot to insert at (1-indexed). Default is 2 (second signer after fee payer).
    ///                    For H2H: Player 1 uses slot 2, Player 2 uses slot 3.
    /// - Returns: Base64-encoded fully-signed transaction
    public func signTransactionBase64(_ transactionBase64: String, signatureSlot: Int = 2) async throws -> String {
        guard let user = await MainActor.run(body: { self.currentUser }) else {
            throw AuthenticationError.notAuthenticated
        }

        // Use the active wallet address, not just .first
        guard let activeWalletAddress = await MainActor.run(body: { self.walletAddress }),
              let wallet = user.embeddedSolanaWallets.first(where: { $0.address == activeWalletAddress }) else {
            throw AuthenticationError.noWalletFound
        }

        do {
            Logger.debug("Signing transaction (base64) with wallet: \(wallet.address), slot: \(signatureSlot)", category: .signing)

            // Extract the message portion (skip signature slots)
            // Solana transaction format: [num_sigs][sig1][sig2]...[MESSAGE]
            // For 2 signatures: byte 0 + (2 * 64 bytes) = first 129 bytes are signatures
            // Message starts at byte 129
            guard let txBytes = Data(base64Encoded: transactionBase64), txBytes.count > 129 else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Transaction too small to extract message"]))
            }

            let numSigs = Int(txBytes[0])
            let messageStart = 1 + (numSigs * 64)
            let messageBytes = txBytes[messageStart...]
            let messageBase64 = messageBytes.base64EncodedString()

            // Privy signs the MESSAGE, not the full transaction
            let signatureString = try await wallet.provider.signMessage(message: messageBase64)

            // Decode transaction from base64
            guard let txBytes = Data(base64Encoded: transactionBase64) else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 transaction"]))
            }

            // Decode signature (try base64 first, then base58)
            var signatureData: Data?
            if let base64Decoded = Data(base64Encoded: signatureString) {
                signatureData = base64Decoded
            } else if let base58Decoded = Base58.decode(signatureString) {
                signatureData = Data(base58Decoded)
            }

            guard let signature = signatureData else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode signature (tried base64 and base58)"]))
            }

            // Add user's signature to transaction
            // Solana transaction format: [num_signatures][signature_1][signature_2]...[message]
            // Signature slots are 64 bytes each, starting at byte 1
            // Slot 1 = bytes 1-64 (fee payer), Slot 2 = bytes 65-128, Slot 3 = bytes 129-192, etc.
            var signedTxBytes = txBytes

            // Calculate byte range for the requested signature slot
            let slotStartByte = 1 + ((signatureSlot - 1) * 64)
            let slotEndByte = slotStartByte + 63  // inclusive
            let minTxSize = slotEndByte + 1  // Need at least this many bytes

            // Check transaction structure
            guard signedTxBytes.count >= minTxSize else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid transaction structure - too small for slot \(signatureSlot) (expected >=\(minTxSize) bytes, got \(signedTxBytes.count))"]))
            }

            guard signature.count >= 64 else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid signature size (expected 64 bytes, got \(signature.count))"]))
            }

            // Read number of signatures
            let numSignatures = Int(signedTxBytes[0])

            guard signatureSlot <= numSignatures else {
                throw AuthenticationError.walletError(NSError(domain: "AuthManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Signature slot \(signatureSlot) exceeds transaction's \(numSignatures) slots"]))
            }

            // Add user's signature at the specified slot
            signedTxBytes.replaceSubrange(slotStartByte...slotEndByte, with: signature.prefix(64))

            // Encode back to base64
            let signedTransactionBase64 = signedTxBytes.base64EncodedString()

            Logger.debug("Transaction signed at slot \(signatureSlot): \(signedTxBytes.count) bytes", category: .signing)

            return signedTransactionBase64

        } catch {
            Logger.error("Error signing transaction (base64): \(error)", category: .signing)
            throw AuthenticationError.walletError(error)
        }
    }

    /// Sign and send a Solana transaction to the network
    /// - Parameter serializedTransaction: Base58-encoded unsigned transaction
    /// - Returns: Transaction signature (hash)
    public func sendTransaction(_ serializedTransaction: String) async throws -> String {
        // First sign the transaction
        let signedTx = try await signTransaction(serializedTransaction)

        // TODO: Submit to Solana network via RPC
        // For now, just return the signed transaction as the "signature"
        Logger.debug("sendTransaction not yet implemented - returning signed tx", category: .signing)

        return signedTx
    }

    // MARK: - Logout

    /// Logout from Privy and clear all session data
    @MainActor
    public func logout() async {
        Logger.info("Logging out from Privy...", category: .auth)

        if let user = currentUser {
            await user.logout()
        }

        self.isAuthenticated = false
        self.currentUser = nil
        self.walletAddress = nil
        self.solanaBalance = 0

        // Clear saved active wallet address
        UserDefaults.standard.removeObject(forKey: "activeWalletAddress")

        delegate?.didLogout()

        Logger.info("User logged out and local state cleared", category: .auth)
    }

    /// Get the Privy instance (use with caution, prefer using manager methods)
    public func getPrivyInstance() -> Privy? {
        privy
    }

    // MARK: - Helper Methods

    // MARK: - Wallet Selection Helpers

    /// Get the active wallet address for the current user
    /// Checks UserDefaults for saved active wallet, otherwise returns first wallet and saves it
    private func getActiveWalletAddress(for user: PrivyUser) -> String? {
        if let savedActiveWallet = UserDefaults.standard.string(forKey: "activeWalletAddress"),
           user.embeddedSolanaWallets.contains(where: { $0.address == savedActiveWallet }) {
            Logger.debug("Using saved active wallet: \(savedActiveWallet)", category: .wallet)
            return savedActiveWallet
        } else if let firstWallet = user.embeddedSolanaWallets.first {
            let address = firstWallet.address
            saveActiveWalletAddress(address)
            Logger.debug("Using first wallet as active: \(address)", category: .wallet)
            return address
        }
        return nil
    }

    /// Save the active wallet address to UserDefaults
    private func saveActiveWalletAddress(_ address: String) {
        UserDefaults.standard.set(address, forKey: "activeWalletAddress")
        Logger.debug("Saved active wallet: \(address)", category: .wallet)
    }

    /// Format wallet address for display (shortened)
    public func formatWalletAddress(_ address: String) -> String {
        if address.count > 10 {
            let start = address.prefix(6)
            let end = address.suffix(4)
            return "\(start)...\(end)"
        }
        return address
    }

    /// Get formatted Solana balance string
    public func formattedSolanaBalance() -> String {
        let balanceDouble = (solanaBalance as NSDecimalNumber).doubleValue
        return String(format: "%.4f", balanceDouble)
    }

    // MARK: - USDC Balance Methods

    /// Get USDC balance in cents from the Privy wallet
    /// - Returns: Balance in cents (e.g., 500 for $5.00)
    public func getCentsBalance() async throws -> Int {
        guard let walletAddress = walletAddress else {
            throw AuthenticationError.noWalletFound
        }

        // Get current network environment to determine which RPC and mint to use
        let networkManager = await NetworkEnvironmentManager.shared
        let currentEnvironment = await networkManager.currentEnvironment

        Logger.debug("Fetching USDC balance for \(walletAddress) on \(currentEnvironment.displayName)", category: .balance)

        // Get the appropriate USDC mint address for the current network
        let usdcMintAddress = BlockchainConfig.getUSDCMint(for: currentEnvironment)

        // Get RPC endpoint from NetworkEnvironmentManager (uses current environment)
        let rpcEndpoint = await networkManager.getRpcEndpoint(for: .solana)

        guard let rpcURL = URL(string: rpcEndpoint) else {
            throw AuthenticationError.walletError(NSError(domain: "ZeroSettle", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid RPC endpoint"]))
        }

        // Derive the Associated Token Account (ATA) for USDC
        let tokenAccountAddress = try await deriveAssociatedTokenAccount(
            walletAddress: walletAddress,
            mintAddress: usdcMintAddress,
            rpcURL: rpcURL
        )

        // Fetch the token account balance
        let balance = try await fetchTokenAccountBalance(
            tokenAccount: tokenAccountAddress,
            rpcURL: rpcURL
        )

        // USDC has 6 decimals, so convert to cents (2 decimals)
        // 1 USDC = 1,000,000 base units = 100 cents
        // So divide by 10,000 to get cents
        let cents = ZeroSettleConstants.USDC.toCents(balance)

        Logger.info("USDC balance: \(ZeroSettleConstants.USDC.formatCents(cents))", category: .balance)

        return cents
    }

    /// Get formatted USDC balance string
    /// - Returns: Formatted balance like "$5.00"
    public func getFormattedBalance() async throws -> String {
        let cents = try await getCentsBalance()
        return String(format: "$%.2f", Double(cents) / 100.0)
    }

    // MARK: - Private Helpers

    private func fetchCurrentUsersSolBalance(
        privy: Privy,
        rpcURL: URL? = nil
    ) async throws -> Decimal {
        await privy.awaitReady()
        guard case .authenticated(let user) = privy.authState else {
            throw NSError(domain: "PrivyAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }

        guard let wallet = user.embeddedSolanaWallets.first else {
            throw NSError(domain: "PrivyWallet", code: 2, userInfo: [NSLocalizedDescriptionKey: "No embedded Solana wallet"])
        }

        // Get RPC URL from NetworkEnvironmentManager if not provided
        let networkManager = await NetworkEnvironmentManager.shared
        let endpoint = await networkManager.getRpcEndpoint(for: .solana)
        let finalRpcURL = rpcURL ?? URL(string: endpoint)!

        var req = URLRequest(url: finalRpcURL)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getBalance",
            "params": [wallet.address]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, _) = try await URLSession.shared.data(for: req)

        let decoded = try JSONDecoder().decode(SolanaGetBalanceResponse.self, from: data)
        let lamports = Decimal(decoded.result?.value ?? 0)
        return lamports / LAMPORTS_PER_SOL
    }

    /// Derive the Associated Token Account (ATA) address for a wallet and token mint
    private func deriveAssociatedTokenAccount(walletAddress: String, mintAddress: String, rpcURL: URL) async throws -> String {
        // Use Solana SDK to derive the ATA address deterministically
        // ATA = findProgramAddress([wallet, TOKEN_PROGRAM_ID, mint], ASSOCIATED_TOKEN_PROGRAM_ID)

        guard let walletPubkey = PublicKey(string: walletAddress),
              let mintPubkey = PublicKey(string: mintAddress) else {
            throw AuthenticationError.walletError(NSError(domain: "ZeroSettle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid wallet or mint address"]))
        }

        // Derive the Associated Token Account address
        let ataResult = PublicKey.associatedTokenAddress(
            walletAddress: walletPubkey,
            tokenMintAddress: mintPubkey
        )

        switch ataResult {
        case .success(let ataAddress):
            let ataString = ataAddress.base58EncodedString
            Logger.debug("Derived ATA address: \(ataString)", category: .balance)
            return ataString

        case .failure(let error):
            Logger.error("Failed to derive ATA: \(error)", category: .balance)
            throw AuthenticationError.walletError(NSError(domain: "ZeroSettle", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to derive token account address: \(error.localizedDescription)"]))
        }
    }

    /// Fetch the balance of a specific token account
    private func fetchTokenAccountBalance(tokenAccount: String, rpcURL: URL) async throws -> UInt64 {
        var req = URLRequest(url: rpcURL)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenAccountBalance",
            "params": [
                tokenAccount,
                ["commitment": "confirmed"]  // Use confirmed commitment for fresh data
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, _) = try await URLSession.shared.data(for: req)

        // Parse response - handle both success and error cases
        struct TokenBalanceResponse: Decodable {
            struct Result: Decodable {
                struct Value: Decodable {
                    let amount: String
                    let decimals: Int
                }
                let value: Value
            }
            struct RPCError: Decodable {
                let code: Int
                let message: String
            }
            let result: Result?
            let error: RPCError?
        }

        let decoded = try JSONDecoder().decode(TokenBalanceResponse.self, from: data)

        // Check for RPC error (e.g., account doesn't exist)
        if let error = decoded.error {
            // If account doesn't exist yet, return 0 balance
            if error.message.contains("could not find account") || error.message.contains("Invalid param") {
                Logger.debug("Token account doesn't exist yet - balance is 0", category: .balance)
                return 0
            }
            Logger.error("RPC Error: \(error.message) (code: \(error.code))", category: .balance)
            throw AuthenticationError.walletError(NSError(domain: "ZeroSettle", code: 3, userInfo: [NSLocalizedDescriptionKey: "RPC Error: \(error.message)"]))
        }

        guard let result = decoded.result,
              let balance = UInt64(result.value.amount) else {
            throw AuthenticationError.walletError(NSError(domain: "ZeroSettle", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse token balance"]))
        }

        return balance
    }
}

// MARK: - Solana RPC Response Models

private struct SolanaGetBalanceResponse: Decodable {
    struct Result: Decodable { let value: UInt64 }
    let result: Result?
}

// MARK: - Errors

public enum AuthenticationError: Error, LocalizedError {
    case notInitialized
    case notAuthenticated
    case authenticationFailed(Error)
    case otpSendFailed(Error)
    case walletError(Error)
    case noWalletFound
    case tokenRetrievalFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Authentication SDK is not initialized"
        case .notAuthenticated:
            return "User is not authenticated"
        case .authenticationFailed(let error):
            return "Authentication failed: \(error.localizedDescription)"
        case .otpSendFailed(let error):
            return "Failed to send OTP: \(error.localizedDescription)"
        case .walletError(let error):
            return "Wallet operation failed: \(error.localizedDescription)"
        case .tokenRetrievalFailed(let error):
            return "Failed to retrieve access token: \(error.localizedDescription)"
        case .noWalletFound:
            return "No wallet found for user"
        }
    }
}
