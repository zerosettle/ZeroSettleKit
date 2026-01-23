import Foundation

/// Supported blockchain networks
public enum BlockchainNetwork: String, Codable, CaseIterable {
    case ethereum = "ethereum"
    case base = "base"
    case arbitrum = "arbitrum"
    case optimism = "optimism"
    case polygon = "polygon"
    case solana = "solana"

    /// Display name for the network
    public var displayName: String {
        switch self {
        case .ethereum: return "Ethereum"
        case .base: return "Base"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        case .polygon: return "Polygon"
        case .solana: return "Solana"
        }
    }

    /// Chain ID for EVM networks (nil for non-EVM like Solana)
    public var chainId: Int? {
        switch self {
        case .ethereum: return 1
        case .base: return 8453
        case .arbitrum: return 42161
        case .optimism: return 10
        case .polygon: return 137
        case .solana: return nil
        }
    }
}

/// Token types supported by the framework
public enum TokenType: Codable, Hashable {
    case native // ETH, SOL, etc.
    case erc20(address: String) // USDC, USDT, etc. on EVM chains
    case spl(mint: String) // Solana Program Library tokens

    public var description: String {
        switch self {
        case .native: return "Native Token"
        case .erc20(let address): return "ERC20: \(address)"
        case .spl(let mint): return "SPL: \(mint)"
        }
    }
}

/// Information about a user's wallet
public struct WalletInfo: Codable {
    /// The wallet address
    public let address: String

    /// The blockchain network
    public let network: BlockchainNetwork

    /// Whether this is a newly created wallet
    public let isNew: Bool

    /// Optional wallet type/provider
    public let type: String?

    public init(address: String, network: BlockchainNetwork, isNew: Bool, type: String? = nil) {
        self.address = address
        self.network = network
        self.isNew = isNew
        self.type = type
    }
}

/// A prepared transaction ready to be signed and sent
public struct PreparedTransaction {
    /// The destination address
    public let to: String

    /// The value being sent (in smallest unit - wei, lamports, etc.)
    public let value: String?

    /// The transaction data/payload
    public let data: String?

    /// The blockchain network
    public let network: BlockchainNetwork

    /// Gas/fee estimates
    public let feeEstimate: FeeEstimate?

    public init(
        to: String,
        value: String? = nil,
        data: String? = nil,
        network: BlockchainNetwork,
        feeEstimate: FeeEstimate? = nil
    ) {
        self.to = to
        self.value = value
        self.data = data
        self.network = network
        self.feeEstimate = feeEstimate
    }
}

/// Transaction receipt after confirmation
public struct TransactionReceipt {
    /// The transaction hash
    public let hash: String

    /// Block number
    public let blockNumber: Int?

    /// Whether the transaction was successful
    public let status: Bool

    /// Gas used
    public let gasUsed: String?

    public init(hash: String, blockNumber: Int?, status: Bool, gasUsed: String?) {
        self.hash = hash
        self.blockNumber = blockNumber
        self.status = status
        self.gasUsed = gasUsed
    }
}

/// Fee estimates for transactions
public struct FeeEstimate {
    /// Estimated gas/fee in native token
    public let estimatedFee: Decimal

    /// The currency of the fee
    public let currency: String

    public init(estimatedFee: Decimal, currency: String) {
        self.estimatedFee = estimatedFee
        self.currency = currency
    }
}
