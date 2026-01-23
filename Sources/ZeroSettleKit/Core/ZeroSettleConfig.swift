import Foundation

/// Network environment for blockchain operations
public enum NetworkEnvironment: String, Codable, CaseIterable {
    case mainnet = "mainnet"
    case devnet = "devnet"

    public var displayName: String {
        switch self {
        case .mainnet: return "Mainnet"
        case .devnet: return "Devnet"
        }
    }
}

/// Configuration for ZeroSettleKit
public struct ZeroSettleConfig {
    // MARK: - Authentication (Privy)

    /// Privy app ID
    public let privyAppId: String

    /// Privy client ID
    public let privyClientId: String

    /// Supported blockchain networks
    public let supportedChains: [BlockchainNetwork]

    // MARK: - Payment Processor

    /// The payment processor to use for fiat onramp
    public let paymentProcessor: PaymentProcessor

    // MARK: - Network Configuration

    /// The default blockchain network
    public let defaultNetwork: BlockchainNetwork

    /// Current network environment (mainnet or devnet)
    public var networkEnvironment: NetworkEnvironment

    /// RPC endpoints for each network
    public let rpcEndpoints: [BlockchainNetwork: String]

    /// Devnet RPC endpoints for each network
    public let devnetRpcEndpoints: [BlockchainNetwork: String]

    // MARK: - UI Configuration (Optional)

    /// Optional theme for UI components
    public let theme: ZeroSettleTheme?

    /// Default funding amounts to show (in cents/smallest unit)
    public let defaultFundingAmounts: [Int]

    // MARK: - ZeroSettle API

    /// Base URL for ZeroSettle partner API calls
    public let apiBaseURL: URL

    /// Partner app identifier that owns payouts (defaults to 2 for WordPlay)
    public let partnerAppId: Int

    /// Optional provider for partner session token to authorize API calls
    public let partnerAuthTokenProvider: (() -> String?)?

    // MARK: - ZeroSettle Backend API

    /// Base URL for ZeroSettle backend API (blockchain transactions, escrow, settlement, etc.)
    /// e.g., http://localhost:8000 or https://zerosettle-backend.com
    public let zeroSettleBackendURL: URL

    /// Provider for ZeroSettle backend authentication token (JWT from Privy login)
    /// ZeroSettleKit will call this to get the current auth token for ZeroSettle API calls
    public let zeroSettleAuthTokenProvider: (() -> String?)?

    // MARK: - Game Backend API

    /// Base URL for the actual game backend API (game logic, scoring, etc.)
    /// e.g., http://localhost:3000 or https://game-backend.com
    public let gameBackendURL: URL?

    /// Provider for game backend authentication token
    /// ZeroSettleKit will call this to get the current auth token for game API calls
    public let gameAuthTokenProvider: (() -> String?)?

    /// Provider for game admin public key (base58-encoded Solana address)
    /// ZeroSettleKit will call this to get the game admin pubkey for blockchain transactions
    public let gameAdminPubkeyProvider: (() -> String?)?

    // MARK: - Initialization

    public init(
        privyAppId: String,
        privyClientId: String,
        supportedChains: [BlockchainNetwork] = [.solana, .base],
        paymentProcessor: PaymentProcessor,
        defaultNetwork: BlockchainNetwork = .base,
        networkEnvironment: NetworkEnvironment = .mainnet,
        rpcEndpoints: [BlockchainNetwork: String] = [:],
        devnetRpcEndpoints: [BlockchainNetwork: String] = [:],
        theme: ZeroSettleTheme? = nil,
        defaultFundingAmounts: [Int] = [100, 200, 300, 500, 1000, 2000], // $1-$20
        apiBaseURL: URL = URL(string: "https://zerosettle.io/api/v1")!,
        partnerAppId: Int = 2,
        partnerAuthTokenProvider: (() -> String?)? = nil,
        zeroSettleBackendURL: URL = URL(string: "http://192.168.1.159:8000")!,
        zeroSettleAuthTokenProvider: (() -> String?)? = nil,
        gameBackendURL: URL? = nil,
        gameAuthTokenProvider: (() -> String?)? = nil,
        gameAdminPubkeyProvider: (() -> String?)? = nil
    ) {
        self.privyAppId = privyAppId
        self.privyClientId = privyClientId
        self.supportedChains = supportedChains
        self.paymentProcessor = paymentProcessor
        self.defaultNetwork = defaultNetwork
        self.networkEnvironment = networkEnvironment
        self.rpcEndpoints = rpcEndpoints
        self.devnetRpcEndpoints = devnetRpcEndpoints
        self.theme = theme
        self.defaultFundingAmounts = defaultFundingAmounts
        self.apiBaseURL = apiBaseURL
        self.partnerAppId = partnerAppId
        self.partnerAuthTokenProvider = partnerAuthTokenProvider
        self.zeroSettleBackendURL = zeroSettleBackendURL
        self.zeroSettleAuthTokenProvider = zeroSettleAuthTokenProvider
        self.gameBackendURL = gameBackendURL
        self.gameAuthTokenProvider = gameAuthTokenProvider
        self.gameAdminPubkeyProvider = gameAdminPubkeyProvider
    }

    // MARK: - Helper Methods

    /// Get the appropriate RPC endpoint for a given network based on current environment
    public func getRpcEndpoint(for network: BlockchainNetwork) -> String {
        switch networkEnvironment {
        case .mainnet:
            return rpcEndpoints[network] ?? getDefaultMainnetEndpoint(for: network)
        case .devnet:
            return devnetRpcEndpoints[network] ?? getDefaultDevnetEndpoint(for: network)
        }
    }

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

/// Theme configuration for UI components
public struct ZeroSettleTheme {
    /// Primary color
    public let primaryColor: ColorHex

    /// Secondary color
    public let secondaryColor: ColorHex

    /// Background gradient colors
    public let backgroundColors: [ColorHex]

    /// Button corner radius
    public let buttonCornerRadius: CGFloat

    public init(
        primaryColor: ColorHex = "#00FF00",
        secondaryColor: ColorHex = "#FFFFFF",
        backgroundColors: [ColorHex] = ["#000000", "#1A1A1A"],
        buttonCornerRadius: CGFloat = 12
    ) {
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.backgroundColors = backgroundColors
        self.buttonCornerRadius = buttonCornerRadius
    }
}

/// Type alias for hex color strings
public typealias ColorHex = String
