//
//  PhantomManager.swift
//  ZeroSettleKit
//
//  Handles Phantom wallet connection via deep links for external wallet deposits
//

import Foundation
import Security
import TweetNacl
import Solana
#if canImport(UIKit)
import UIKit
#endif

/// Manages Phantom wallet connections via deep links
public final class PhantomManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = PhantomManager()

    // MARK: - Published Properties

    /// Whether a Phantom wallet is currently connected
    @Published public private(set) var isConnected: Bool = false

    /// The connected wallet's public key (Solana address)
    @Published public private(set) var publicKey: String?

    /// Session token for subsequent Phantom operations
    @Published public private(set) var session: String?

    /// Error message if connection or transaction failed
    @Published public private(set) var errorMessage: String?

    /// Whether a transaction is currently pending signature
    @Published public private(set) var isTransactionPending: Bool = false

    /// The last signed transaction (base58 encoded)
    @Published public private(set) var lastSignedTransaction: String?

    // MARK: - Callbacks

    /// Callback when connected successfully
    public var onConnected: ((String) -> Void)?  // Called with wallet address

    /// Callback when connection fails
    public var onConnectionError: ((String) -> Void)?

    /// Callback when a transaction is signed successfully
    public var onTransactionSigned: ((String) -> Void)?

    /// Callback when a transaction signing fails
    public var onTransactionError: ((String) -> Void)?

    // MARK: - Private Properties

    /// Our dApp's keypair for encryption with Phantom
    private var dappSecretKey: Data?
    private var dappPublicKey: Data?

    /// Phantom's public key for encryption (received on connection)
    private var phantomEncryptionPublicKey: Data?

    /// Shared secret for encryption/decryption
    private var sharedSecret: Data?

    // MARK: - Configuration

    /// App URL for Phantom to fetch metadata
    private var appURL: String = "https://zerosettle.com"

    /// Solana cluster to use
    private var cluster: Network = .mainnetBeta

    /// URL scheme for redirects back to the app
    private var redirectScheme: String = "zerosettle"

    // MARK: - UserDefaults Keys

    private enum StorageKeys {
        static let session = "PhantomManager.session"
        static let publicKey = "PhantomManager.publicKey"
        static let phantomEncryptionPublicKey = "PhantomManager.phantomEncryptionPublicKey"
        static let dappSecretKey = "PhantomManager.dappSecretKey"
        static let isConnected = "PhantomManager.isConnected"
    }

    // MARK: - Initialization

    private init() {
        loadPersistedState()
    }

    // MARK: - Configuration

    /// Configure the Phantom manager with your app's settings
    public func configure(appURL: String, redirectScheme: String, cluster: Network = .mainnetBeta) {
        self.appURL = appURL
        self.redirectScheme = redirectScheme
        self.cluster = cluster

        Logger.info("Phantom configured: scheme=\(redirectScheme), cluster=\(cluster.cluster)", category: .wallet)
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let defaults = UserDefaults.standard

        // Load or generate dApp keypair
        if let secretKey = defaults.data(forKey: StorageKeys.dappSecretKey),
           secretKey.count == 32 {
            do {
                let keyPair = try NaclBox.keyPair(fromSecretKey: secretKey)
                dappSecretKey = keyPair.secretKey
                dappPublicKey = keyPair.publicKey
                Logger.debug("Loaded existing dApp keypair", category: .wallet)
            } catch {
                Logger.warning("Failed to load keypair: \(error)", category: .wallet)
                generateNewKeyPair()
            }
        } else {
            generateNewKeyPair()
        }

        // Load connection state
        if defaults.bool(forKey: StorageKeys.isConnected) {
            session = defaults.string(forKey: StorageKeys.session)
            publicKey = defaults.string(forKey: StorageKeys.publicKey)

            if let phantomPubKeyData = defaults.data(forKey: StorageKeys.phantomEncryptionPublicKey),
               let secretKey = dappSecretKey {
                phantomEncryptionPublicKey = phantomPubKeyData

                // Recompute shared secret
                do {
                    sharedSecret = try NaclBox.before(publicKey: phantomPubKeyData, secretKey: secretKey)
                } catch {
                    Logger.warning("Failed to compute shared secret: \(error)", category: .wallet)
                }
            }

            if session != nil && publicKey != nil && sharedSecret != nil {
                isConnected = true
                Logger.info("Restored Phantom connection: \(publicKey ?? "")", category: .wallet)
            } else {
                Logger.warning("Incomplete persisted state, clearing", category: .wallet)
                clearPersistedState()
            }
        }
    }

    private func persistConnectionState() {
        let defaults = UserDefaults.standard

        defaults.set(isConnected, forKey: StorageKeys.isConnected)
        defaults.set(session, forKey: StorageKeys.session)
        defaults.set(publicKey, forKey: StorageKeys.publicKey)
        defaults.set(phantomEncryptionPublicKey, forKey: StorageKeys.phantomEncryptionPublicKey)

        if let secretKey = dappSecretKey {
            defaults.set(secretKey, forKey: StorageKeys.dappSecretKey)
        }

        defaults.synchronize()
        Logger.debug("Persisted connection state", category: .wallet)
    }

    private func clearPersistedState() {
        let defaults = UserDefaults.standard

        defaults.removeObject(forKey: StorageKeys.isConnected)
        defaults.removeObject(forKey: StorageKeys.session)
        defaults.removeObject(forKey: StorageKeys.publicKey)
        defaults.removeObject(forKey: StorageKeys.phantomEncryptionPublicKey)

        defaults.synchronize()
        Logger.debug("Cleared persisted state", category: .wallet)
    }

    private func generateNewKeyPair() {
        do {
            let keyPair = try NaclBox.keyPair()
            dappSecretKey = keyPair.secretKey
            dappPublicKey = keyPair.publicKey

            UserDefaults.standard.set(keyPair.secretKey, forKey: StorageKeys.dappSecretKey)
            UserDefaults.standard.synchronize()
            Logger.debug("Generated new dApp keypair", category: .wallet)
        } catch {
            Logger.error("Failed to generate keypair: \(error)", category: .wallet)
        }
    }

    // MARK: - Connection

    /// Initiate a connection to Phantom wallet
    public func connect() {
        guard let dappPubKey = dappPublicKey else {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to generate encryption key"
                self.onConnectionError?("Failed to generate encryption key")
            }
            return
        }

        let dappPublicKeyBase58 = Base58.encode([UInt8](dappPubKey))
        let redirectLink = "\(redirectScheme)://phantom-connect"

        Logger.info("Initiating Phantom connection", category: .wallet)

        var components = URLComponents(string: "https://phantom.app/ul/v1/connect")!
        components.queryItems = [
            URLQueryItem(name: "app_url", value: appURL),
            URLQueryItem(name: "dapp_encryption_public_key", value: dappPublicKeyBase58),
            URLQueryItem(name: "redirect_link", value: redirectLink),
            URLQueryItem(name: "cluster", value: cluster.cluster)
        ]

        guard let url = components.url else {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to build connection URL"
                self.onConnectionError?("Failed to build connection URL")
            }
            return
        }

        openURL(url)
    }

    // MARK: - Sign Transaction

    /// Request Phantom to sign a pre-built transaction
    /// - Parameter transactionBase58: The serialized transaction encoded in base58
    public func signTransaction(_ transactionBase58: String) {
        guard isConnected, let session = session else {
            DispatchQueue.main.async {
                self.errorMessage = "Not connected to Phantom"
                self.onTransactionError?("Not connected")
            }
            return
        }

        guard let dappPubKey = dappPublicKey, let sharedSecret = sharedSecret else {
            DispatchQueue.main.async {
                self.errorMessage = "No encryption keys available"
                self.onTransactionError?("No encryption keys")
            }
            return
        }

        let dappPublicKeyBase58 = Base58.encode([UInt8](dappPubKey))

        Logger.debug("Preparing transaction for signing (\(transactionBase58.count) chars)", category: .signing)

        // Build payload
        let payload: [String: Any] = [
            "transaction": transactionBase58,
            "session": session
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            Logger.error("Failed to serialize payload JSON", category: .signing)
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create payload"
                self.onTransactionError?("Failed to create payload")
            }
            return
        }

        // Encrypt payload
        guard let (encryptedPayload, nonce) = encryptPayload(payloadData) else {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to encrypt payload"
                self.onTransactionError?("Failed to encrypt payload")
            }
            return
        }

        let redirectLink = "\(redirectScheme)://phantom-signTransaction"

        var components = URLComponents(string: "https://phantom.app/ul/v1/signTransaction")!
        components.queryItems = [
            URLQueryItem(name: "dapp_encryption_public_key", value: dappPublicKeyBase58),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "redirect_link", value: redirectLink),
            URLQueryItem(name: "payload", value: encryptedPayload)
        ]

        guard let url = components.url else {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to build sign URL"
                self.onTransactionError?("Failed to build sign URL")
            }
            return
        }

        DispatchQueue.main.async {
            self.isTransactionPending = true
        }

        if url.absoluteString.count > 8000 {
            Logger.warning("Sign URL very long (\(url.absoluteString.count) chars)", category: .signing)
        }

        Logger.info("Opening Phantom for transaction signing", category: .signing)
        openURL(url)
    }


    /// Build a USDC transfer transaction from Phantom wallet to a destination token account
    /// - Parameters:
    ///   - fromTokenAccount: Source USDC token account (ATA) address (base58)
    ///   - toTokenAccount: Destination USDC token account (ATA) address (base58)
    ///   - amount: Amount in USDC base units (1 USDC = 1,000,000 units)
    ///   - rpcEndpoint: The Solana RPC endpoint to use (defaults to current network environment)
    ///   - completion: Called with the serialized transaction (base58) or an error
    public func buildUSDCTransferTransaction(
        fromTokenAccount: String,
        toTokenAccount: String,
        amount: UInt64,
        rpcEndpoint: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard isConnected, let walletAddress = publicKey else {
            completion(.failure(PhantomTransactionError.notConnected))
            return
        }

        Logger.info("Building USDC transfer: \(Double(amount) / 1_000_000) USDC", category: .signing)

        Task {
            do {
                // Use provided RPC endpoint or get from network environment
                let effectiveRpcEndpoint: String
                if let rpcEndpoint = rpcEndpoint {
                    effectiveRpcEndpoint = rpcEndpoint
                } else {
                    effectiveRpcEndpoint = await NetworkEnvironmentManager.shared.getSolanaRpcEndpoint()
                }

                let currentNetwork = await NetworkEnvironmentManager.shared.currentEnvironment
                let solanaNetwork: Network = currentNetwork == .mainnet ? .mainnetBeta : .devnet

                Logger.debug("Using \(currentNetwork.displayName) RPC", category: .network)

                let endpoint = RPCEndpoint(url: URL(string: effectiveRpcEndpoint)!, urlWebSocket: URL(string: effectiveRpcEndpoint.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://"))!, network: solanaNetwork)
                let solana = Solana(router: NetworkingRouter(endpoint: endpoint))

                // Check if token accounts exist and have sufficient balance
                try await checkTokenAccountExists(solana: solana, tokenAccount: fromTokenAccount, label: "Source")
                try await checkTokenAccountExists(solana: solana, tokenAccount: toTokenAccount, label: "Destination")

                // Check Phantom wallet SOL balance (for transaction fees)
                try await checkSOLBalance(solana: solana, wallet: walletAddress)

                // Check source account USDC balance
                try await checkUSDCBalance(solana: solana, tokenAccount: fromTokenAccount, required: amount)

                // Get the appropriate USDC mint based on current network environment
                let usdcMintAddress = BlockchainConfig.getUSDCMint(for: currentNetwork)

                guard let usdcMint = PublicKey(string: usdcMintAddress) else {
                    throw PhantomTransactionError.invalidAddress
                }

                // Get latest blockhash
                let blockhash = try await solana.api.getLatestBlockhash()

                // Parse addresses
                guard let ownerPubkey = PublicKey(string: walletAddress),
                      let sourcePubkey = PublicKey(string: fromTokenAccount),
                      let destinationPubkey = PublicKey(string: toTokenAccount) else {
                    throw PhantomTransactionError.invalidAddress
                }

                // Create transfer checked instruction (safer than regular transfer)
                let instruction = TokenProgram.transferCheckedInstruction(
                    programId: .tokenProgramId,
                    source: sourcePubkey,
                    mint: usdcMint,
                    destination: destinationPubkey,
                    owner: ownerPubkey,
                    multiSigners: [],
                    amount: amount,
                    decimals: 6  // USDC has 6 decimals
                )

                // Create transaction with ONE empty signature slot for Phantom to fill
                var transaction = Transaction(
                    signatures: [Transaction.Signature(signature: nil, publicKey: ownerPubkey)],
                    feePayer: ownerPubkey,
                    instructions: [instruction],
                    recentBlockhash: blockhash
                )

                // Serialize (unsigned)
                let serializeResult = transaction.serialize(requiredAllSignatures: false, verifySignatures: false)
                guard case .success(let serializedData) = serializeResult else {
                    if case .failure(let error) = serializeResult {
                        Logger.error("Serialization failed: \(error)", category: .signing)
                        throw error
                    }
                    throw PhantomTransactionError.transactionBuildFailed("Failed to serialize transaction")
                }

                let transactionBytes = [UInt8](serializedData)
                let transactionBase58 = Base58.encode(transactionBytes)

                Logger.info("USDC transaction built: \(serializedData.count) bytes", category: .signing)

                completion(.success(transactionBase58))
            } catch {
                Logger.error("Failed to build USDC transaction: \(error)", category: .signing)
                completion(.failure(error))
            }
        }
    }


    /// Convenience method to deposit USDC to a Privy wallet
    /// - Parameters:
    ///   - fromTokenAccount: Your Phantom wallet's USDC token account (ATA) address
    ///   - toTokenAccount: Privy wallet's USDC token account (ATA) address
    ///   - amountUSDC: Amount in USDC (e.g., 5.0 for $5.00)
    ///   - rpcEndpoint: The Solana RPC endpoint to use (defaults to current network environment)
    public func depositUSDCToPrivyWallet(
        fromTokenAccount: String,
        toTokenAccount: String,
        amountUSDC: Double,
        rpcEndpoint: String? = nil
    ) {
        let baseUnits = UInt64(amountUSDC * 1_000_000)

        buildUSDCTransferTransaction(
            fromTokenAccount: fromTokenAccount,
            toTokenAccount: toTokenAccount,
            amount: baseUnits,
            rpcEndpoint: rpcEndpoint
        ) { [weak self] result in
            switch result {
            case .success(let transactionBase58):
                self?.signTransaction(transactionBase58)

            case .failure(let error):
                DispatchQueue.main.async {
                    self?.errorMessage = "Failed to build USDC transaction: \(error.localizedDescription)"
                    self?.onTransactionError?(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helper Functions

    private func checkTokenAccountExists(solana: Solana, tokenAccount: String, label: String) async throws {
        do {
            // Try to get account info using continuation wrapper
            let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BufferInfoPureData, Error>) in
                solana.api.getAccountInfo(account: tokenAccount) { result in
                    continuation.resume(with: result)
                }
            }

            Logger.debug("\(label) token account exists", category: .balance)
        } catch {
            Logger.error("\(label) token account not found", category: .balance)

            // Get network-specific error message
            let currentNetwork = await NetworkEnvironmentManager.shared.currentEnvironment
            let errorMessage: String

            if currentNetwork == .mainnet {
                errorMessage = "\(label) USDC account not found. Your Phantom wallet needs to receive USDC first to create the token account. You can purchase USDC on exchanges like Coinbase or use the 'Apple Pay' option in this app."
            } else {
                errorMessage = "\(label) USDC account not found. Get free test USDC on Devnet:\n1. Visit https://spl-token-faucet.com/\n2. Enter your Phantom wallet address\n3. Select USDC mint: Gh9ZwEmdLJ8DscKNTkTqPbNwLNNBjuSzaG9Vp2KGtKJr\n4. Click 'Airdrop' to receive test tokens\n\nAlternatively, use 'Apple Pay' option to test deposits."
            }

            throw PhantomTransactionError.transactionBuildFailed(errorMessage)
        }
    }

    private func checkUSDCBalance(solana: Solana, tokenAccount: String, required: UInt64) async throws {
        do {
            // Get token account info
            let accountInfo = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BufferInfo<AccountInfo>, Error>) in
                solana.api.getAccountInfo(account: tokenAccount, decodedTo: AccountInfo.self) { result in
                    continuation.resume(with: result)
                }
            }

            // Access the decoded AccountInfo from Buffer
            guard let tokenAccountData = accountInfo.data.value else {
                Logger.error("Token account data could not be decoded", category: .balance)
                throw PhantomTransactionError.transactionBuildFailed("Could not decode token account data")
            }

            // AccountInfo.lamports is the USDC token balance
            let balance = tokenAccountData.lamports

            if balance < required {
                Logger.error("Insufficient USDC: \(Double(balance) / 1_000_000) < \(Double(required) / 1_000_000)", category: .balance)
                throw PhantomTransactionError.transactionBuildFailed("Insufficient USDC. Source account has $\(Double(balance) / 1_000_000), need $\(Double(required) / 1_000_000)")
            }

            Logger.debug("USDC balance sufficient: \(Double(balance) / 1_000_000)", category: .balance)
        } catch let error as PhantomTransactionError {
            throw error
        } catch {
            Logger.warning("Could not verify USDC balance: \(error)", category: .balance)
            // Don't fail on balance check errors - Phantom will reject if insufficient
        }
    }

    private func checkSOLBalance(solana: Solana, wallet: String) async throws {
        do {
            // Get wallet SOL balance
            let balance = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt64, Error>) in
                solana.api.getBalance(account: wallet, commitment: nil) { result in
                    continuation.resume(with: result)
                }
            }

            // Need at least 0.00001 SOL for transaction fees
            if balance < 10_000 {
                Logger.warning("Very low SOL balance for fees: \(balance) lamports", category: .balance)
            }
        } catch {
            Logger.warning("Could not verify SOL balance: \(error)", category: .balance)
            // Don't fail - Phantom will reject if insufficient
        }
    }

    // MARK: - Encryption/Decryption

    private func encryptPayload(_ data: Data) -> (encrypted: String, nonce: String)? {
        guard let sharedSecret = sharedSecret else {
            Logger.error("No shared secret available for encryption", category: .signing)
            return nil
        }

        do {
            // Generate 24 random bytes for the nonce using Swift's secure random number generator
            var nonce = Data(count: 24)
            let result = nonce.withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(kSecRandomDefault, 24, bytes.baseAddress!)
            }
            guard result == errSecSuccess else {
                Logger.error("Failed to generate random nonce", category: .signing)
                return nil
            }

            let encrypted = try NaclSecretBox.secretBox(message: data, nonce: nonce, key: sharedSecret)

            let encryptedBase58 = Base58.encode([UInt8](encrypted))
            let nonceBase58 = Base58.encode([UInt8](nonce))

            Logger.debug("Encrypted payload: \(encrypted.count) bytes", category: .signing)

            return (encryptedBase58, nonceBase58)
        } catch {
            Logger.error("Encryption failed: \(error)", category: .signing)
            return nil
        }
    }

    private func decryptPayload(_ encryptedBase58: String, nonceBase58: String) -> Data? {
        guard let sharedSecret = sharedSecret else { return nil }

        guard let encryptedBytes = Base58.decode(encryptedBase58),
              let nonceBytes = Base58.decode(nonceBase58) else {
            Logger.error("Failed to decode base58", category: .signing)
            return nil
        }

        do {
            let decrypted = try NaclSecretBox.open(
                box: Data(encryptedBytes),
                nonce: Data(nonceBytes),
                key: sharedSecret
            )
            return decrypted
        } catch {
            Logger.error("Decryption failed: \(error)", category: .signing)
            return nil
        }
    }

    // MARK: - Handle Redirects

    @discardableResult
    public func handleRedirect(url: URL) -> Bool {
        guard let host = url.host else { return false }

        switch host {
        case "phantom-connect":
            return handleConnectRedirect(url: url)
        case "phantom-signTransaction":
            return handleSignTransactionRedirect(url: url)
        default:
            return false
        }
    }

    private func handleConnectRedirect(url: URL) -> Bool {
        Logger.debug("Received connect redirect", category: .wallet)

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return true
        }

        // Check for errors
        if let errorCode = components.queryItems?.first(where: { $0.name == "errorCode" })?.value,
           let errorMsg = components.queryItems?.first(where: { $0.name == "errorMessage" })?.value {
            Logger.error("Connection rejected: \(errorCode) - \(errorMsg)", category: .wallet)
            DispatchQueue.main.async {
                self.isConnected = false
                self.errorMessage = "Connection rejected: \(errorMsg)"
                self.onConnectionError?(errorMsg)
            }
            return true
        }

        // Extract parameters
        guard let phantomPubKeyBase58 = components.queryItems?.first(where: { $0.name == "phantom_encryption_public_key" })?.value,
              let nonceBase58 = components.queryItems?.first(where: { $0.name == "nonce" })?.value,
              let dataBase58 = components.queryItems?.first(where: { $0.name == "data" })?.value else {
            Logger.error("Missing connect parameters", category: .wallet)
            return true
        }

        // Decode Phantom's public key
        guard let phantomPubKeyBytes = Base58.decode(phantomPubKeyBase58) else {
            Logger.error("Failed to decode Phantom public key", category: .wallet)
            return true
        }

        let phantomPubKey = Data(phantomPubKeyBytes)
        phantomEncryptionPublicKey = phantomPubKey

        // Compute shared secret
        guard let secretKey = dappSecretKey else {
            Logger.error("No dApp secret key", category: .wallet)
            return true
        }

        do {
            sharedSecret = try NaclBox.before(publicKey: phantomPubKey, secretKey: secretKey)
        } catch {
            Logger.error("Failed to compute shared secret: \(error)", category: .wallet)
            return true
        }

        // Decrypt response
        guard let decrypted = decryptPayload(dataBase58, nonceBase58: nonceBase58),
              let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
            Logger.error("Failed to decrypt connection response", category: .wallet)
            return true
        }

        guard let walletPubKey = json["public_key"] as? String,
              let sessionToken = json["session"] as? String else {
            Logger.error("Missing public_key or session", category: .wallet)
            return true
        }

        DispatchQueue.main.async {
            self.publicKey = walletPubKey
            self.session = sessionToken
            self.isConnected = true
            self.errorMessage = nil
            self.persistConnectionState()
            self.onConnected?(walletPubKey)
        }

        Logger.info("Phantom wallet connected: \(walletPubKey)", category: .wallet)

        return true
    }

    private func handleSignTransactionRedirect(url: URL) -> Bool {
        Logger.debug("Received signTransaction redirect", category: .signing)

        DispatchQueue.main.async {
            self.isTransactionPending = false
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return true
        }

        // Check for errors
        if let errorCode = components.queryItems?.first(where: { $0.name == "errorCode" })?.value,
           let errorMsg = components.queryItems?.first(where: { $0.name == "errorMessage" })?.value {
            Logger.error("Transaction rejected: \(errorCode) - \(errorMsg)", category: .signing)
            DispatchQueue.main.async {
                self.errorMessage = "Transaction rejected: \(errorMsg)"
            }
            onTransactionError?(errorMsg)
            return true
        }

        // Extract parameters
        guard let nonceBase58 = components.queryItems?.first(where: { $0.name == "nonce" })?.value,
              let dataBase58 = components.queryItems?.first(where: { $0.name == "data" })?.value else {
            Logger.error("Missing parameters in sign response", category: .signing)
            onTransactionError?("Missing parameters in response")
            return true
        }

        // Decrypt response
        guard let decrypted = decryptPayload(dataBase58, nonceBase58: nonceBase58),
              let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any],
              let signedTransaction = json["transaction"] as? String else {
            Logger.error("Failed to decrypt transaction response", category: .signing)
            onTransactionError?("Failed to decrypt response")
            return true
        }

        DispatchQueue.main.async {
            self.lastSignedTransaction = signedTransaction
            self.errorMessage = nil
        }

        Logger.info("Transaction signed successfully", category: .signing)

        // Now send the signed transaction to Solana
        sendSignedTransaction(signedTransaction)

        return true
    }

    // MARK: - Send Transaction

    /// Send a signed transaction to the Solana network
    /// - Parameters:
    ///   - signedTransactionBase58: The signed, serialized transaction (base58 encoded)
    ///   - rpcEndpoint: The Solana RPC endpoint to use (defaults to current network environment)
    public func sendSignedTransaction(
        _ signedTransactionBase58: String,
        rpcEndpoint: String? = nil
    ) {
        Task {
            // Use provided RPC endpoint or get from network environment
            let effectiveRpcEndpoint: String
            if let rpcEndpoint = rpcEndpoint {
                effectiveRpcEndpoint = rpcEndpoint
            } else {
                effectiveRpcEndpoint = await NetworkEnvironmentManager.shared.getSolanaRpcEndpoint()
            }

            let currentNetwork = await NetworkEnvironmentManager.shared.currentEnvironment
            let solanaNetwork: Network = currentNetwork == .mainnet ? .mainnetBeta : .devnet

            Logger.info("Sending transaction to Solana (\(currentNetwork.displayName))", category: .network)

            do {
                // Decode the base58 transaction
                guard let transactionBytes = Base58.decode(signedTransactionBase58) else {
                    throw PhantomTransactionError.transactionBuildFailed("Failed to decode signed transaction")
                }

                // Create Solana connection
                let endpoint = RPCEndpoint(
                    url: URL(string: effectiveRpcEndpoint)!,
                    urlWebSocket: URL(string: effectiveRpcEndpoint.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://"))!,
                    network: solanaNetwork
                )
                let solana = Solana(router: NetworkingRouter(endpoint: endpoint))

                // Send the raw transaction (convert to base64 string)
                let transactionData = Data(transactionBytes)
                let transactionBase64 = transactionData.base64EncodedString()

                let signature = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransactionID, Error>) in
                    solana.api.sendTransaction(
                        serializedTransaction: transactionBase64,
                        configs: RequestConfiguration(encoding: "base64")!
                    ) { result in
                        continuation.resume(with: result)
                    }
                }

                Logger.info("Transaction sent: \(signature)", category: .signing)

                // Call success callback
                onTransactionSigned?(signature)

            } catch {
                Logger.error("Failed to send transaction: \(error)", category: .signing)

                DispatchQueue.main.async {
                    self.errorMessage = "Failed to send transaction: \(error.localizedDescription)"
                }

                onTransactionError?(error.localizedDescription)
            }
        }
    }

    // MARK: - Disconnect

    public func disconnect() {
        clearPersistedState()

        DispatchQueue.main.async {
            self.isConnected = false
            self.publicKey = nil
            self.session = nil
            self.phantomEncryptionPublicKey = nil
            self.sharedSecret = nil
            self.errorMessage = nil
            self.isTransactionPending = false
            self.lastSignedTransaction = nil
        }

        generateNewKeyPair()
        Logger.info("Phantom disconnected", category: .wallet)
    }

    // MARK: - Helpers

    private func openURL(_ url: URL) {
#if canImport(UIKit)
        // Ensure UI operations happen on main thread
        DispatchQueue.main.async {
            UIApplication.shared.open(url) { success in
                if !success {
                    DispatchQueue.main.async {
                        self.errorMessage = "Could not open Phantom. Make sure it's installed."
                        self.onConnectionError?("Could not open Phantom")
                    }
                }
            }
        }
#endif
    }

    public func formatWalletAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    public func formatUSDC(cents: Int) -> String {
        return String(format: "$%.2f", Double(cents) / 100.0)
    }
}

// MARK: - Base58 Encoding/Decoding

public enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base = alphabet.count

    /// Encode bytes to Base58 string
    public static func encode(_ bytes: [UInt8]) -> String {
        var bytes = bytes
        var result = ""

        // Count leading zeros
        var leadingZeros = 0
        for byte in bytes {
            if byte == 0 {
                leadingZeros += 1
            } else {
                break
            }
        }

        // Encode
        while !bytes.isEmpty && bytes.contains(where: { $0 != 0 }) {
            var carry = 0
            var newBytes: [UInt8] = []

            for byte in bytes {
                carry = carry * 256 + Int(byte)
                newBytes.append(UInt8(carry / base))
                carry = carry % base
            }

            // Remove leading zeros from newBytes
            while let first = newBytes.first, first == 0 {
                newBytes.removeFirst()
            }

            bytes = newBytes
            result = String(alphabet[carry]) + result
        }

        // Add leading 1s for leading zeros
        result = String(repeating: "1", count: leadingZeros) + result

        return result
    }

    /// Decode Base58 string to bytes
    public static func decode(_ string: String) -> [UInt8]? {
        var result: [UInt8] = []
        var leadingOnes = 0

        for char in string {
            if char == "1" {
                leadingOnes += 1
            } else {
                break
            }
        }

        for char in string {
            guard let index = alphabet.firstIndex(of: char) else {
                return nil
            }

            var carry = index
            for i in (0..<result.count).reversed() {
                carry += Int(result[i]) * base
                result[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }

            while carry > 0 {
                result.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }

        // Add leading zeros
        result = [UInt8](repeating: 0, count: leadingOnes) + result

        return result
    }
}

// MARK: - Phantom Transaction Errors

/// Errors that can occur during Phantom transaction operations
public enum PhantomTransactionError: LocalizedError {
    case notConnected
    case invalidAddress
    case transactionBuildFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Phantom wallet is not connected"
        case .invalidAddress:
            return "Invalid Solana address"
        case .transactionBuildFailed(let message):
            return "Failed to build transaction: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}
