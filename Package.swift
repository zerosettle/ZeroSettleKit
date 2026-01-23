// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZeroSettleKit",
    platforms: [
        .iOS(.v17)
    ],

    // MARK: - Products (What consumers import)
    products: [
        // Combined: Both Escrow and IAP
        .library(
            name: "ZeroSettleKit",
            targets: ["ZeroSettleEscrow", "ZeroSettleIAP"]
        ),
        // Skill-based gaming with blockchain escrow
        .library(
            name: "ZeroSettleEscrow",
            targets: ["ZeroSettleEscrow"]
        ),
        // Merchant of Record web checkout
        .library(
            name: "ZeroSettleIAP",
            targets: ["ZeroSettleIAP"]
        ),
    ],

    // MARK: - Dependencies
    dependencies: [
        // Auth: Privy SDK for authentication and embedded wallets
        .package(url: "https://github.com/privy-io/privy-ios.git", from: "2.5.1"),
        // Crypto: TweetNacl for NaCl encryption (Phantom deep links)
        .package(url: "https://github.com/bitmark-inc/tweetnacl-swiftwrap.git", from: "1.1.0"),
        // Blockchain: Solana Swift SDK
        .package(url: "https://github.com/metaplex-foundation/Solana.Swift", from: "2.0.0"),
        // Wallets: MetaMask iOS SDK
        .package(url: "https://github.com/MetaMask/metamask-ios-sdk", from: "0.8.10"),
        // Wallets: Coinbase Wallet SDK
        .package(url: "https://github.com/MobileWalletProtocol/wallet-mobile-sdk.git", from: "1.0.3"),
    ],

    // MARK: - Targets
    targets: [
        // ────────────────────────────────────────────────────────────
        // INTERNAL: Core (NOT exported to consumers)
        // Contains: Logging, HTTP, Extensions, Constants
        // ────────────────────────────────────────────────────────────
        .target(
            name: "ZeroSettleCore",
            dependencies: [],
            path: "Sources/Core"
        ),

        // ────────────────────────────────────────────────────────────
        // INTERNAL: Auth
        // Contains: Privy integration, session management
        // ────────────────────────────────────────────────────────────
        .target(
            name: "ZeroSettleAuth",
            dependencies: [
                "ZeroSettleCore",
                .product(name: "Privy", package: "privy-ios"),
            ],
            path: "Sources/Auth"
        ),

        // ────────────────────────────────────────────────────────────
        // INTERNAL: Blockchain
        // Contains: Transaction building, PDA derivation, RPC
        // ────────────────────────────────────────────────────────────
        .target(
            name: "ZeroSettleBlockchain",
            dependencies: [
                "ZeroSettleCore",
                .product(name: "Solana", package: "Solana.Swift"),
            ],
            path: "Sources/Blockchain"
        ),

        // ────────────────────────────────────────────────────────────
        // INTERNAL: Wallets
        // Contains: MetaMask, Phantom, Coinbase integrations
        // ────────────────────────────────────────────────────────────
        .target(
            name: "ZeroSettleWallets",
            dependencies: [
                "ZeroSettleCore",
                .product(name: "metamask-ios-sdk", package: "metamask-ios-sdk"),
                .product(name: "CoinbaseWalletSDK", package: "wallet-mobile-sdk"),
                .product(name: "TweetNacl", package: "tweetnacl-swiftwrap"),
            ],
            path: "Sources/Wallets"
        ),

        // ────────────────────────────────────────────────────────────
        // PUBLIC: Escrow Product
        // High-level API for skill-based gaming with escrow
        // ────────────────────────────────────────────────────────────
        .target(
            name: "ZeroSettleEscrow",
            dependencies: [
                "ZeroSettleCore",
                "ZeroSettleAuth",
                "ZeroSettleBlockchain",
                "ZeroSettleWallets",
            ],
            path: "Sources/Escrow",
            resources: [
                .process("Resources")
            ]
        ),

        // ────────────────────────────────────────────────────────────
        // PUBLIC: IAP Product
        // High-level API for Merchant of Record checkout
        // ────────────────────────────────────────────────────────────
        .target(
            name: "ZeroSettleIAP",
            dependencies: [
                "ZeroSettleCore",
            ],
            path: "Sources/IAP"
        ),

        // ────────────────────────────────────────────────────────────
        // TESTS
        // ────────────────────────────────────────────────────────────
        .testTarget(
            name: "ZeroSettleCoreTests",
            dependencies: ["ZeroSettleCore"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "ZeroSettleEscrowTests",
            dependencies: ["ZeroSettleEscrow"],
            path: "Tests/EscrowTests"
        ),
        .testTarget(
            name: "ZeroSettleIAPTests",
            dependencies: ["ZeroSettleIAP"],
            path: "Tests/IAPTests"
        ),
    ]
)
