//
//  AuthenticationManager.swift
//  ZeroSettleAuth
//
//  Manages Privy authentication and embedded Solana wallet operations.
//

import Foundation
import Combine
import PrivySDK
import ZeroSettleCore

// MARK: - Auth Configuration

public struct AuthConfig: Sendable {
    public let privyAppId: String
    public let privyClientId: String

    public init(privyAppId: String, privyClientId: String) {
        self.privyAppId = privyAppId
        self.privyClientId = privyClientId
    }
}

// MARK: - Auth Session

public struct AuthSession: Sendable {
    public let userId: String
    public let walletAddress: String
    public let isNewWallet: Bool

    public init(userId: String, walletAddress: String, isNewWallet: Bool = false) {
        self.userId = userId
        self.walletAddress = walletAddress
        self.isNewWallet = isNewWallet
    }
}

// MARK: - Auth Errors

public enum AuthError: Error, LocalizedError {
    case notInitialized
    case notAuthenticated
    case authenticationFailed(Error)
    case otpSendFailed(Error)
    case walletCreationFailed(Error)
    case signingFailed(Error)
    case noWalletFound

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
        case .walletCreationFailed(let error):
            return "Failed to create wallet: \(error.localizedDescription)"
        case .signingFailed(let error):
            return "Signing failed: \(error.localizedDescription)"
        case .noWalletFound:
            return "No wallet found for user"
        }
    }
}

// MARK: - Authentication Manager

@MainActor
public final class AuthenticationManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var session: AuthSession?

    // MARK: - Private State

    private var privy: Privy?
    private var currentUser: PrivyUser?
    private let config: AuthConfig

    #if DEBUG
    private let logLevel: PrivyLogLevel = .verbose
    #else
    private let logLevel: PrivyLogLevel = .none
    #endif

    // MARK: - Initialization

    public init(config: AuthConfig) {
        self.config = config
        Logger.info("AuthenticationManager created", category: .auth)
    }

    /// Initialize Privy SDK. Call once at app launch.
    public func initialize() async {
        guard !isInitialized else {
            Logger.debug("Already initialized", category: .auth)
            return
        }

        Logger.info("Initializing Privy SDK...", category: .auth)

        let privyConfig = PrivyConfig(
            appId: config.privyAppId,
            appClientId: config.privyClientId,
            loggingConfig: .init(logLevel: logLevel)
        )

        privy = PrivySdk.initialize(config: privyConfig)
        isInitialized = true

        Logger.info("Privy SDK initialized", category: .auth)
    }

    /// Check and restore existing session if available.
    public func restoreSession() async {
        guard let privy else {
            Logger.debug("Privy not initialized", category: .auth)
            return
        }

        let authState = await privy.getAuthState()

        switch authState {
        case .authenticated(let user):
            currentUser = user
            if let address = resolveActiveWallet(for: user) {
                session = AuthSession(userId: user.id, walletAddress: address)
                isAuthenticated = true
                Logger.info("Session restored for user: \(user.id)", category: .auth)
            }

        case .unauthenticated, .notReady, .authenticatedUnverified:
            isAuthenticated = false
            session = nil
            currentUser = nil
            Logger.debug("No session to restore", category: .auth)
        }
    }

    // MARK: - SMS OTP Authentication

    /// Send OTP code to phone number.
    /// - Parameter phoneNumber: Phone in E.164 format (e.g., "+14155552671")
    public func sendOTP(to phoneNumber: String) async throws {
        guard let privy else {
            throw AuthError.notInitialized
        }

        do {
            try await privy.sms.sendCode(to: phoneNumber)
            Logger.info("OTP sent to \(phoneNumber.prefix(6))...", category: .auth)
        } catch {
            Logger.error("Failed to send OTP: \(error)", category: .auth)
            throw AuthError.otpSendFailed(error)
        }
    }

    /// Verify OTP and complete login.
    /// - Parameters:
    ///   - code: The 6-digit OTP code
    ///   - phoneNumber: Phone in E.164 format
    /// - Returns: The authenticated session
    @discardableResult
    public func verifyOTP(code: String, phoneNumber: String) async throws -> AuthSession {
        guard let privy else {
            throw AuthError.notInitialized
        }

        do {
            let user = try await privy.sms.loginWithCode(code, sentTo: phoneNumber)
            currentUser = user

            // Create wallet if needed
            var walletAddress: String
            var isNewWallet = false

            if user.embeddedSolanaWallets.isEmpty {
                Logger.info("Creating Solana wallet...", category: .wallet)
                let wallet = try await user.createSolanaWallet(allowAdditional: false)
                walletAddress = wallet.address
                isNewWallet = true
                saveActiveWallet(wallet.address)
                Logger.info("Created wallet: \(walletAddress.formatAsAddress())", category: .wallet)
            } else {
                walletAddress = resolveActiveWallet(for: user) ?? user.embeddedSolanaWallets.first!.address
            }

            let newSession = AuthSession(
                userId: user.id,
                walletAddress: walletAddress,
                isNewWallet: isNewWallet
            )

            session = newSession
            isAuthenticated = true

            Logger.info("Login successful: \(user.id)", category: .auth)
            return newSession

        } catch {
            Logger.error("Login failed: \(error)", category: .auth)
            throw AuthError.authenticationFailed(error)
        }
    }

    // MARK: - Access Token

    /// Get the current JWT access token for API authentication.
    /// - Returns: The JWT token, or nil if not authenticated
    public func getAccessToken() async -> String? {
        guard let user = currentUser else {
            Logger.debug("getAccessToken: No currentUser set", category: .auth)
            return nil
        }
        do {
            let token = try await user.getAccessToken()
            Logger.debug("getAccessToken: Retrieved token (length: \(token.count))", category: .auth)
            return token
        } catch {
            Logger.error("getAccessToken: Failed to get token: \(error)", category: .auth)
            return nil
        }
    }

    // MARK: - Logout

    public func logout() async {
        Logger.info("Logging out...", category: .auth)

        if let user = currentUser {
            await user.logout()
        }

        isAuthenticated = false
        session = nil
        currentUser = nil
        UserDefaults.standard.removeObject(forKey: "activeWalletAddress")

        Logger.info("Logged out", category: .auth)
    }

    // MARK: - Transaction Signing

    /// Sign a message with the user's embedded wallet.
    /// - Parameter messageBase64: Base64-encoded message bytes
    /// - Returns: Base58-encoded signature
    public func signMessage(_ messageBase64: String) async throws -> String {
        let wallet = try getActiveWallet()

        do {
            let signatureString = try await wallet.provider.signMessage(message: messageBase64)

            // Privy returns base64, convert to base58
            if let signatureData = Data(base64Encoded: signatureString) {
                return Base58.encode(signatureData)
            }
            return signatureString

        } catch {
            Logger.error("Signing failed: \(error)", category: .signing)
            throw AuthError.signingFailed(error)
        }
    }

    /// Sign a Solana transaction and insert signature at specified slot.
    /// - Parameters:
    ///   - transactionBase64: Base64-encoded transaction
    ///   - signatureSlot: Slot index (1-indexed). Slot 1 = fee payer, Slot 2 = first cosigner, etc.
    /// - Returns: Base64-encoded signed transaction
    public func signTransaction(_ transactionBase64: String, signatureSlot: Int = 2) async throws -> String {
        let wallet = try getActiveWallet()

        guard let txBytes = Data(base64Encoded: transactionBase64) else {
            throw AuthError.signingFailed(NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid base64 transaction"]))
        }

        // Extract message from transaction
        // Format: [num_sigs][sig1][sig2]...[MESSAGE]
        let numSigs = Int(txBytes[0])
        let messageStart = 1 + (numSigs * 64)

        guard txBytes.count > messageStart else {
            throw AuthError.signingFailed(NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transaction too small"]))
        }

        let messageBytes = txBytes[messageStart...]
        let messageBase64 = messageBytes.base64EncodedString()

        // Sign the message
        let signatureString = try await wallet.provider.signMessage(message: messageBase64)

        // Decode signature
        var signatureData: Data?
        if let base64 = Data(base64Encoded: signatureString) {
            signatureData = base64
        } else if let base58 = Base58.decode(signatureString) {
            signatureData = base58
        }

        guard let signature = signatureData, signature.count == 64 else {
            throw AuthError.signingFailed(NSError(domain: "Auth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid signature"]))
        }

        // Insert signature at slot
        var signedTx = txBytes
        let slotStart = 1 + ((signatureSlot - 1) * 64)
        let slotEnd = slotStart + 63

        guard signedTx.count > slotEnd, signatureSlot <= numSigs else {
            throw AuthError.signingFailed(NSError(domain: "Auth", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid signature slot"]))
        }

        signedTx.replaceSubrange(slotStart...slotEnd, with: signature.prefix(64))

        Logger.debug("Transaction signed at slot \(signatureSlot)", category: .signing)
        return signedTx.base64EncodedString()
    }

    // MARK: - Private Helpers

    private func getActiveWallet() throws -> EmbeddedSolanaWallet {
        guard let user = currentUser else {
            throw AuthError.notAuthenticated
        }

        guard let address = session?.walletAddress,
              let wallet = user.embeddedSolanaWallets.first(where: { $0.address == address }) else {
            throw AuthError.noWalletFound
        }

        return wallet
    }

    private func resolveActiveWallet(for user: PrivyUser) -> String? {
        // Check saved preference
        if let saved = UserDefaults.standard.string(forKey: "activeWalletAddress"),
           user.embeddedSolanaWallets.contains(where: { $0.address == saved }) {
            return saved
        }

        // Fall back to first wallet
        if let first = user.embeddedSolanaWallets.first {
            saveActiveWallet(first.address)
            return first.address
        }

        return nil
    }

    private func saveActiveWallet(_ address: String) {
        UserDefaults.standard.set(address, forKey: "activeWalletAddress")
    }
}
