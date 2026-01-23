import Foundation
import Combine
import Solana

/// Main manager that coordinates authentication, funding, and wallet operations
@MainActor
public class ZeroSettleManager: ObservableObject {

    // MARK: - Published Properties

    /// Whether the manager is initialized
    @Published public private(set) var isInitialized: Bool = false

    /// Whether user is authenticated
    @Published public private(set) var isAuthenticated: Bool = false

    /// Current wallet address (if authenticated)
    @Published public private(set) var walletAddress: String?

    /// Current balances by token type
    @Published public private(set) var balances: [TokenType: Decimal] = [:]

    /// Pending transaction hashes
    @Published public private(set) var pendingTransactions: [String] = []

    /// Current network environment
    @Published public private(set) var networkEnvironment: NetworkEnvironment

    // MARK: - Public Properties

    /// Delegate for callbacks
    public weak var delegate: ZeroSettleDelegate? {
        didSet {
            authManager.delegate = delegate
        }
    }

    /// Configuration
    public let config: ZeroSettleConfig

    /// Authentication manager
    public let authManager: AuthenticationManager

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private let payoutService: PayoutTableService

    // MARK: - Initialization

    public init(config: ZeroSettleConfig) {
        self.config = config
        self.networkEnvironment = config.networkEnvironment
        self.authManager = AuthenticationManager(config: config)
        self.payoutService = PayoutTableService(config: config)

        // Set up observers
        setupObservers()

        Logger.info("ZeroSettleManager initialized with \(networkEnvironment.displayName)", category: .general)
    }

    /// Initialize with an existing AuthenticationManager (recommended for apps with shared auth)
    public init(config: ZeroSettleConfig, authManager: AuthenticationManager) {
        self.config = config
        self.networkEnvironment = config.networkEnvironment
        self.authManager = authManager
        self.payoutService = PayoutTableService(config: config)

        // Set up observers
        setupObservers()

        Logger.info("ZeroSettleManager initialized with shared AuthenticationManager", category: .general)
    }

    // MARK: - Payout Tables

    /// Fetch the latest payout table configured for this partner app
    /// - Returns: Normalized payout table containing sorted tiers
    public func fetchLatestPayoutTable() async throws -> ZeroSettlePayoutTable {
        try await payoutService.fetchLatestPayoutTable()
    }

    // MARK: - Setup

    private func setupObservers() {
        // Observe authentication state changes
        authManager.$isAuthenticated
            .sink { [weak self] isAuth in
                self?.isAuthenticated = isAuth
            }
            .store(in: &cancellables)

        authManager.$walletAddress
            .sink { [weak self] address in
                self?.walletAddress = address
            }
            .store(in: &cancellables)

        authManager.$isInitialized
            .sink { [weak self] isInit in
                self?.isInitialized = isInit
            }
            .store(in: &cancellables)
    }

    // MARK: - Initialization Methods

    /// Initialize the manager (runs in background)
    public func initialize() async {
        Logger.info("Initializing...", category: .general)
        await authManager.initializeInBackground()
        Logger.info("Initialization complete", category: .general)
    }

    // MARK: - Authentication

    /// Send OTP code to phone number
    /// - Parameter phoneNumber: Phone number in E.164 format (e.g., "+14155552671")
    public func sendOTPCode(to phoneNumber: String) async throws {
        try await authManager.sendOTPCode(to: phoneNumber)
    }

    /// Verify OTP and login
    /// - Parameters:
    ///   - code: The 6-digit OTP code
    ///   - phoneNumber: Phone number in E.164 format
    public func loginWithOTP(code: String, phoneNumber: String) async throws {
        try await authManager.loginWithOTP(code: code, phoneNumber: phoneNumber)
    }

    /// Logout
    public func logout() async {
        await authManager.logout()
        balances = [:]
        pendingTransactions = []
    }

    // MARK: - Funding

    /// Initiate a funding transaction
    /// - Parameters:
    ///   - amount: Amount in fiat currency (e.g., Decimal(3.00) for $3.00)
    ///   - currency: Currency code (e.g., "USD")
    ///   - destination: Optional destination address (uses authenticated wallet if nil)
    /// - Returns: A funding session with payment URL
    public func initiateFunding(
        amount: Decimal,
        currency: String = "USD",
        destination: String? = nil
    ) async throws -> FundingSession {
        guard isAuthenticated else {
            throw ZeroSettleError.notAuthenticated
        }

        let destinationAddress = destination ?? walletAddress ?? ""
        guard !destinationAddress.isEmpty else {
            throw ZeroSettleError.noWalletFound
        }

        delegate?.didInitiateFunding(amount: amount, currency: currency)

        do {
            let session = try await config.paymentProcessor.initiateFunding(
                amount: amount,
                currency: currency,
                destination: destinationAddress,
                network: config.defaultNetwork
            )

            Logger.info("Funding session created: \(session.sessionId)", category: .balance)
            return session
        } catch {
            delegate?.didFailFunding(error: error)
            throw error
        }
    }

    /// Handle a payment completion event
    /// - Parameters:
    ///   - success: Whether the payment succeeded
    ///   - amount: The amount funded
    ///   - transactionHash: Optional blockchain transaction hash
    public func handlePaymentCompletion(success: Bool, amount: Decimal, transactionHash: String? = nil) {
        if success {
            delegate?.didCompleteFunding(amount: amount, currency: "USD", transactionHash: transactionHash)
        } else {
            delegate?.didFailFunding(error: ZeroSettleError.paymentFailed)
        }
    }

    // MARK: - Transactions

    /// Send a transaction
    /// - Parameter transaction: The prepared transaction
    /// - Returns: Transaction hash
    public func sendTransaction(_ transaction: PreparedTransaction) async throws -> String {
        guard isAuthenticated else {
            throw ZeroSettleError.notAuthenticated
        }

        delegate?.willSendTransaction(transaction: transaction)

        do {
            // For Solana transactions, use the auth manager
            let txHash = try await authManager.sendTransaction(transaction.data ?? "")

            pendingTransactions.append(txHash)
            delegate?.didSendTransaction(txHash: txHash)

            return txHash
        } catch {
            delegate?.didFailTransaction(error: error)
            throw error
        }
    }

    /// Monitor a transaction
    /// - Parameter txHash: Transaction hash to monitor
    public func monitorTransaction(_ txHash: String) {
        // TODO: Implement transaction monitoring
        Logger.debug("Monitoring transaction: \(txHash)", category: .network)
    }

    // MARK: - Wallet Operations

    /// Sign a message with the user's wallet
    /// - Parameter message: The message to sign
    /// - Returns: The signature
    public func signMessage(_ message: String) async throws -> String {
        try await authManager.signMessage(message)
    }

    /// Sign base64-encoded message bytes and return base58 signature
    /// Used for atomic Solana transactions where server builds the tx
    /// - Parameter messageBase64: Base64-encoded Solana message bytes
    /// - Returns: Base58-encoded signature
    public func signMessageBase64(_ messageBase64: String) async throws -> String {
        try await authManager.signMessageBase64(messageBase64)
    }

    /// Format a wallet address for display
    /// - Parameter address: The full address
    /// - Returns: Shortened address (e.g., "0x1234...5678")
    public func formatAddress(_ address: String) -> String {
        authManager.formatWalletAddress(address)
    }

    // MARK: - Balance Operations

    /// Get USDC balance in cents from the Privy wallet
    /// - Returns: Balance in cents (e.g., 500 for $5.00)
    public func getCentsBalance() async throws -> Int {
        try await authManager.getCentsBalance()
    }

    /// Get formatted USDC balance string
    /// - Returns: Formatted balance like "$5.00"
    public func getFormattedBalance() async throws -> String {
        try await authManager.getFormattedBalance()
    }

    // MARK: - Network Environment Management

    /// Switch network environment (requires reinitialization)
    /// - Parameter environment: The network environment to switch to
    /// - Note: This will update the config and require a re-initialization
    public func switchNetworkEnvironment(_ environment: NetworkEnvironment) {
        guard environment != networkEnvironment else {
            Logger.debug("Already on \(environment.displayName)", category: .network)
            return
        }

        // Update the config's network environment
        var mutableConfig = config
        mutableConfig.networkEnvironment = environment

        // Update published property
        networkEnvironment = environment

        Logger.info("Switched to \(environment.displayName)", category: .network)
    }

    /// Get the current RPC endpoint for the default network
    public func getCurrentRpcEndpoint() -> String {
        config.getRpcEndpoint(for: config.defaultNetwork)
    }

    // MARK: - Game Sessions

    /// Start a game session with automatic transaction signing and submission
    /// This method handles all blockchain operations transparently:
    /// 1. Creates game session on backend (backend partially signs transaction)
    /// 2. Signs transaction with user's Privy wallet
    /// 3. Submits transaction to Solana
    /// 4. Returns game session details
    ///
    /// - Parameters:
    ///   - gameDefinitionId: The game definition ID
    ///   - entryFeeCents: Entry fee in cents
    ///   - payoutFunctionId: Optional payout function ID
    ///   - maxPayoutMultiplier: Maximum payout multiplier
    /// - Returns: Game session UUID string
    public func startGameSession(
        gameDefinitionId: Int,
        entryFeeCents: Int,
        payoutFunctionId: Int? = nil,
        maxPayoutMultiplier: Double
    ) async throws -> String {
        Logger.info("Starting game session...", category: .general)

        guard isAuthenticated else {
            throw ZeroSettleError.notAuthenticated
        }

        guard let walletAddress = walletAddress else {
            throw ZeroSettleError.noWalletFound
        }

        guard let gameAdminPubkey = config.gameAdminPubkeyProvider?() else {
            Logger.error("No game admin pubkey available", category: .general)
            throw ZeroSettleError.configurationError("Game admin pubkey not configured")
        }

        guard let authToken = config.zeroSettleAuthTokenProvider?() else {
            Logger.error("No auth token available", category: .auth)
            throw ZeroSettleError.notAuthenticated
        }

        // Step 1: Call ZeroSettle backend to start session and get partially-signed transaction
        Logger.debug("Requesting game session from backend...", category: .network)
        let url = config.zeroSettleBackendURL.appendingPathComponent("/api/v1/sessions/start/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        // Convert cents to USDC lamports (6 decimals)
        // cents * 10,000 = lamports (because 1 USDC = 100 cents = 1,000,000 lamports)
        let entryFeeLamports = entryFeeCents * 10_000

        let payload: [String: Any] = [
            "game_definition_id": gameDefinitionId,
            "entry_fee": entryFeeLamports,
            "payout_function_id": payoutFunctionId as Any,
            "build_transaction": true,
            "user_pubkey": walletAddress,
            "game_admin_pubkey": gameAdminPubkey,
            "max_payout_multiplier": maxPayoutMultiplier
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start game session"]))
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let gameSessionId = json?["game_session_id"] as? String else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server"]))
        }

        Logger.info("Game session created: \(gameSessionId)", category: .general)

        // Step 2: Extract blockchain transaction if present
        guard let blockchainTx = json?["blockchain_transaction"] as? [String: Any],
              let partiallySignedTx = blockchainTx["partially_signed_transaction"] as? String,
              let feePayer = blockchainTx["fee_payer"] as? String else {
            Logger.debug("No blockchain transaction in response", category: .signing)
            return gameSessionId
        }

        Logger.debug("Received partially-signed tx from backend (fee payer: \(feePayer))", category: .signing)

        // Step 3: Sign transaction with user's wallet
        let fullySignedTxBase64 = try await authManager.signTransactionBase64(partiallySignedTx)

        // Step 4: Submit to Solana
        let rpcEndpoint = await NetworkEnvironmentManager.shared.getSolanaRpcEndpoint()
        let cluster = await NetworkEnvironmentManager.shared.currentEnvironment == .devnet ? "devnet" : "mainnet-beta"

        Logger.info("Submitting transaction to Solana (\(cluster))", category: .network)

        do {
            // Create Solana connection
            let endpoint = RPCEndpoint(
                url: URL(string: rpcEndpoint)!,
                urlWebSocket: URL(string: rpcEndpoint.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://"))!,
                network: rpcEndpoint.contains("devnet") ? .devnet : .mainnetBeta
            )
            let solana = Solana(router: NetworkingRouter(endpoint: endpoint))

            let signature = try await solana.api.sendTransaction(
                serializedTransaction: fullySignedTxBase64,
                configs: RequestConfiguration(encoding: "base64")!
            )

            Logger.info("Transaction submitted: \(signature)", category: .signing)

            // Wait for transaction confirmation
            let confirmed = try await waitForTransactionConfirmation(
                signature: signature,
                solana: solana,
                maxAttempts: 30,
                delayMs: 500
            )

            guard confirmed else {
                throw ZeroSettleError.transactionFailed("Transaction confirmation timed out")
            }

            Logger.info("Player stake complete for session \(gameSessionId)", category: .signing)

            return gameSessionId

        } catch {
            Logger.error("Transaction failed: \(error.localizedDescription)", category: .signing)
            throw ZeroSettleError.transactionFailed(error.localizedDescription)
        }
    }

    public func submitGameAdminStakeTransaction(
        gameSessionId: String,
        gameDefinitionId: Int,
        entryFeeCents: Int,
        payoutFunctionId: Int? = nil,
        maxPayoutMultiplier: Double
    ) async throws {
        guard let walletAddress = walletAddress else {
            throw ZeroSettleError.noWalletFound
        }

        // For now, just do dummy stuff
        let playerUrl = config.gameBackendURL!.appendingPathComponent("/player")
        var playerRequest = URLRequest(url: playerUrl)
        playerRequest.httpMethod = "GET"
        let (playerData, playerResponse) = try await URLSession.shared.data(for: playerRequest)

        guard let httpResponse = playerResponse as? HTTPURLResponse, httpResponse.statusCode == 201 else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create player"]))
        }

        let playerJson = try JSONSerialization.jsonObject(with: playerData) as? [String: Any]
        guard let playerId = playerJson?["id"] as? String else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server"]))
        }

        // Convert cents to USDC lamports (6 decimals)
        // cents * 10,000 = lamports (because 1 USDC = 100 cents = 1,000,000 lamports)
        let entryFeeLamports = entryFeeCents * 10_000

        let gameUrl = config.gameBackendURL!.appendingPathComponent("/matches/create/\(playerId)")
        var gameRequest = URLRequest(url: gameUrl)
        gameRequest.httpMethod = "POST"
        gameRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "game_definition_id": gameDefinitionId,
            "entry_fee": entryFeeLamports,
            "payout_function_id": payoutFunctionId as Any,
            "build_transaction": true,
            "user_pubkey": walletAddress,
            "max_payout_multiplier": maxPayoutMultiplier
        ]
        gameRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (gameData, gameResponse) = try await URLSession.shared.data(for: gameRequest)

        guard let httpResponse = gameResponse as? HTTPURLResponse, httpResponse.statusCode == 201 else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start game session"]))
        }

        let gameJson = try JSONSerialization.jsonObject(with: gameData) as? [String: Any]
        guard let gameId = gameJson?["game_id"] as? String else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server"]))
        }

        let stakeUrl = config.gameBackendURL!.appendingPathComponent("/stake")
        var stakeRequest = URLRequest(url: stakeUrl)
        stakeRequest.httpMethod = "POST"
        stakeRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let stakePayload: [String: Any] = [
            "game_session_id": gameSessionId,
            "game_definition_id": gameDefinitionId,
            "entry_fee": entryFeeLamports,
            "max_payout_multiplier": maxPayoutMultiplier,
            "user_pubkey": walletAddress
        ]
        stakeRequest.httpBody = try JSONSerialization.data(withJSONObject: stakePayload)

        let (stakeData, stakeResponse) = try await URLSession.shared.data(for: stakeRequest)
        guard let httpResponse = stakeResponse as? HTTPURLResponse, httpResponse.statusCode < 300 else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to stake game admin funds"]))
        }

        Logger.debug("Waiting for transaction confirmation...", category: .signing)
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: - Game Staking

    /// Build and sign a stake transaction using relayer pattern
    /// Flow: Backend builds & signs → Client verifies & signs → Client submits
    /// - Parameters:
    ///   - gameSessionId: The game session UUID from the backend
    ///   - stakeAmountCents: The stake amount in cents (e.g., 300 for $3.00)
    ///   - maxPayoutMultiplier: The maximum payout multiplier from the payout table
    /// - Returns: Fully signed transaction as base64 string, ready to submit
    public func createSignedStakeTransaction(
        gameSessionId: String,
        stakeAmountCents: Int,
        maxPayoutMultiplier: Double
    ) async throws -> String {
        guard isAuthenticated else {
            throw ZeroSettleError.notAuthenticated
        }

        guard let walletAddress = walletAddress else {
            throw ZeroSettleError.noWalletFound
        }

        guard let gameAdminPubkey = config.gameAdminPubkeyProvider?() else {
            Logger.error("No game admin pubkey available", category: .general)
            throw ZeroSettleError.configurationError("Game admin pubkey not configured")
        }

        Logger.debug("Requesting stake tx: \(stakeAmountCents) cents, session \(gameSessionId)", category: .signing)

        // Step 1: Send intent to ZeroSettle backend
        let url = config.zeroSettleBackendURL.appendingPathComponent("/api/v1/blockchain/build-player-stake/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Convert cents to USDC lamports (6 decimals)
        // cents * 10,000 = lamports (because 1 USDC = 100 cents = 1,000,000 lamports)
        let stakeAmountLamports = stakeAmountCents * 10_000

        let payload: [String: Any] = [
            "user_pubkey": walletAddress,
            "game_admin_pubkey": gameAdminPubkey,
            "stake_amount_cents": stakeAmountLamports,
            "game_session_id": gameSessionId,
            "max_payout_multiplier": maxPayoutMultiplier
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZeroSettleError.transactionFailed()
        }

        guard httpResponse.statusCode == 200 else {
            Logger.error("Backend returned status \(httpResponse.statusCode)", category: .network)
            throw ZeroSettleError.transactionFailed()
        }

        struct BuildTransactionResponse: Codable {
            let success: Bool
            let partially_signed_transaction: String
            let fee_payer: String
            let instructions_count: Int
            let game_session_id: Int
        }

        let buildResponse = try JSONDecoder().decode(BuildTransactionResponse.self, from: data)

        guard buildResponse.success else {
            Logger.error("Backend failed to build transaction", category: .signing)
            throw ZeroSettleError.transactionFailed()
        }

        Logger.debug("Received partially-signed tx, now signing with user wallet", category: .signing)

        let fullySignedTransaction = try await authManager.signTransaction(
            buildResponse.partially_signed_transaction
        )

        Logger.info("Transaction fully signed, ready to submit", category: .signing)

        return fullySignedTransaction
    }

    // MARK: - Game Flow Management

    /// Confirm escrow after both player and game admin have staked
    /// This validates that the escrow vault balance matches expected amounts
    /// Should be called after:
    /// 1. Player has staked (via startGameSession)
    /// 2. Game admin has staked (via their server calling game_stake endpoint)
    ///
    /// - Parameter gameSessionId: The game session UUID
    /// - Returns: Transaction signature of the confirm operation
    public func confirmEscrow(gameSessionId: String) async throws -> String {
        Logger.info("Confirming escrow for session \(gameSessionId)", category: .signing)

        guard let authToken = config.zeroSettleAuthTokenProvider?() else {
            throw ZeroSettleError.notAuthenticated
        }

        let url = config.zeroSettleBackendURL.appendingPathComponent("/api/v1/sessions/\(gameSessionId)/confirm-escrow/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "platform_rate_bps": 500  // 5% platform fee
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        guard httpResponse.statusCode == 200 else {
            if let errorStr = String(data: data, encoding: .utf8) {
                Logger.error("Confirm escrow failed: \(errorStr)", category: .signing)
            }
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to confirm escrow"]))
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let signature = json?["tx_signature"] as? String else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid confirm response"]))
        }

        Logger.info("Escrow confirmed: \(signature)", category: .signing)

        return signature
    }

    /// Submit final game result to game admin server for settlement
    /// The game admin server will build and submit the blockchain settlement transaction
    ///
    /// - Parameters:
    ///   - gameSessionId: The game session UUID
    ///   - userPubkey: Player's Solana wallet address
    ///   - finalMultiplier: Final payout multiplier in basis points (e.g., 250 for 2.5x)
    /// - Returns: Transaction signature from the blockchain settlement
    public func submitGameResult(
        gameSessionId: String,
        userPubkey: String,
        finalMultiplier: Int
    ) async throws -> String {
        Logger.info("Submitting game result: session=\(gameSessionId), multiplier=\(Double(finalMultiplier)/100)x", category: .general)

        guard let gameBackendURL = config.gameBackendURL else {
            throw ZeroSettleError.configurationError("Game backend URL not configured")
        }

        let url = gameBackendURL.appendingPathComponent("/submit-result")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "game_session_id": gameSessionId,
            "user_pubkey": userPubkey,
            "final_multiplier": finalMultiplier
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        guard httpResponse.statusCode == 200 else {
            if let errorStr = String(data: data, encoding: .utf8) {
                Logger.error("Submit result failed: \(errorStr)", category: .general)
            }
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to submit game result"]))
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let signature = json?["tx_signature"] as? String else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response - no signature"]))
        }

        Logger.info("Game result submitted: \(signature)", category: .signing)

        return signature
    }

    /// Notify ZeroSettle backend that settlement is complete
    /// This is called after submitGameResult to record the settlement in the database
    ///
    /// - Parameters:
    ///   - gameSessionId: The game session UUID
    ///   - platformFeeBps: Platform fee in basis points (default 500 = 5%)
    /// - Returns: Transaction signature (returned from backend for reference)
    public func settleGame(
        gameSessionId: String,
        platformFeeBps: Int = 500
    ) async throws -> String {
        Logger.info("Recording settlement for session \(gameSessionId)", category: .general)

        guard let authToken = config.zeroSettleAuthTokenProvider?() else {
            throw ZeroSettleError.notAuthenticated
        }

        let url = config.zeroSettleBackendURL.appendingPathComponent("/api/v1/sessions/\(gameSessionId)/settle/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "platform_rate_bps": platformFeeBps
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        guard httpResponse.statusCode == 200 else {
            if let errorStr = String(data: data, encoding: .utf8) {
                Logger.error("Settlement recording failed: \(errorStr)", category: .general)
            }
            throw ZeroSettleError.networkError(NSError(domain: "ZeroSettle", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to record settlement"]))
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let txSig = json?["tx_signature"] as? String ?? ""

        Logger.info("Settlement recorded", category: .general)

        return txSig
    }

    // MARK: - Transaction Confirmation

    /// Polls for transaction confirmation until confirmed or max attempts reached
    /// - Parameters:
    ///   - signature: The transaction signature to check
    ///   - solana: The Solana API instance
    ///   - maxAttempts: Maximum number of polling attempts (default 30)
    ///   - delayMs: Delay between attempts in milliseconds (default 500)
    /// - Returns: true if confirmed, false if timed out
    private func waitForTransactionConfirmation(
        signature: String,
        solana: Solana,
        maxAttempts: Int = 30,
        delayMs: UInt64 = 500
    ) async throws -> Bool {
        for attempt in 1...maxAttempts {
            do {
                let statuses = try await solana.api.getSignatureStatuses(pubkeys: [signature])

                if let status = statuses.first, let signatureStatus = status {
                    // Check for errors
                    if signatureStatus.err != nil {
                        Logger.error("Transaction failed on-chain", category: .signing)
                        throw ZeroSettleError.transactionFailed("Transaction failed on-chain")
                    }

                    // Check confirmation status
                    if let confirmationStatus = signatureStatus.confirmationStatus {
                        if confirmationStatus == .confirmed || confirmationStatus == .finalized {
                            Logger.info("Transaction confirmed (\(confirmationStatus.rawValue)) after \(attempt) attempt(s)", category: .signing)
                            return true
                        }
                        Logger.debug("Confirmation attempt \(attempt)/\(maxAttempts): \(confirmationStatus.rawValue)", category: .signing)
                    } else {
                        Logger.debug("Confirmation attempt \(attempt)/\(maxAttempts): waiting...", category: .signing)
                    }
                } else {
                    Logger.debug("Confirmation attempt \(attempt)/\(maxAttempts): tx not found", category: .signing)
                }
            } catch let error as ZeroSettleError {
                throw error
            } catch {
                Logger.warning("Confirmation attempt \(attempt)/\(maxAttempts) error: \(error.localizedDescription)", category: .signing)
            }

            // Wait before next attempt
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }

        Logger.warning("Transaction confirmation timed out after \(maxAttempts) attempts", category: .signing)
        return false
    }
}

// MARK: - Errors

public enum ZeroSettleError: Error, LocalizedError {
    case notInitialized
    case notAuthenticated
    case noWalletFound
    case paymentFailed
    case transactionFailed(String? = nil)
    case networkError(Error)
    case configurationError(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "ZeroSettle is not initialized"
        case .notAuthenticated:
            return "User is not authenticated"
        case .noWalletFound:
            return "No wallet found for user"
        case .paymentFailed:
            return "Payment failed or was cancelled"
        case .transactionFailed(let details):
            if let details = details {
                return "Transaction failed: \(details)"
            }
            return "Transaction failed"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        }
    }
}
