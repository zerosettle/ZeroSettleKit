# ZeroSettleKit

A Swift package for iOS that enables seamless fiat-to-crypto onboarding with phone authentication, Apple Pay, and embedded wallets.

## Features

- 📱 **Phone Authentication** - SMS-based login with Privy SDK
- 🔐 **Embedded Wallets** - Automatic Solana wallet creation
- 💳 **Apple Pay → Crypto** - Coinbase Commerce integration for USDC onramp
- 🦊 **MetaMask Integration** - Full Ethereum wallet support with MetaMask iOS SDK
- 👻 **Phantom Wallet** - Solana wallet deep linking support
- ⛓️ **Multi-Chain Ready** - Designed to support multiple blockchains (Solana + Ethereum)
- 🎨 **Customizable UI** - Optional SwiftUI components with theming
- 🔌 **Protocol-Based** - Easily swap payment processors

## Installation

### Swift Package Manager

Add ZeroSettleKit to your project:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/ZeroSettleKit.git", from: "0.1.0")
]
```

Or in Xcode:
1. File → Add Packages...
2. Enter the repository URL
3. Select version and add to your target

## Quick Start

### 1. Configure ZeroSettleKit

```swift
import ZeroSettleKit

// Create a Coinbase payment processor
let coinbaseProcessor = CoinbasePaymentProcessor(
    apiKeyId: "your-coinbase-api-key-id",
    apiKeySecret: "your-coinbase-api-secret",
    environment: .production
)

// Configure ZeroSettle
let config = ZeroSettleConfig(
    privyAppId: "your-privy-app-id",
    privyClientId: "your-privy-client-id",
    supportedChains: [.solana, .base],
    paymentProcessor: coinbaseProcessor,
    defaultNetwork: .base,
    partnerAppId: 2 // Replace with your partner app ID
)

// Initialize the manager
let zeroSettle = ZeroSettleManager(config: config)
zeroSettle.delegate = self
```

### 2. Initialize (in your App or Scene)

```swift
@main
struct MyApp: App {
    @StateObject private var zeroSettle: ZeroSettleManager

    init() {
        let config = ZeroSettleConfig(...)
        _zeroSettle = StateObject(wrappedValue: ZeroSettleManager(config: config))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(zeroSettle)
                .environmentObject(zeroSettle.authManager)
                .task {
                    await zeroSettle.initialize()
                }
        }
    }
}
```

### 3. Authenticate Users

```swift
// Send OTP
try await zeroSettle.sendOTPCode(to: "+14155552671")

// Verify OTP and login
try await zeroSettle.loginWithOTP(code: "123456", phoneNumber: "+14155552671")

// User now has an embedded Solana wallet!
print("Wallet: \(zeroSettle.walletAddress)")
```

### 4. Add Funds

```swift
// Initiate funding session
let session = try await zeroSettle.initiateFunding(
    amount: Decimal(3.00),
    currency: "USD"
)

// Load session.paymentURL in a WKWebView
// User completes Apple Pay checkout
// Coinbase sends USDC to user's wallet
```

### 5. Fetch the latest payout table

```swift
let payoutTable = try await zeroSettle.fetchLatestPayoutTable()
for tier in payoutTable.tiers {
    print("\(tier.guessesUsed) guesses → \(tier.multiplier)x")
}
```

`partnerAppId` defaults to `2` (WordPlay) but you can configure it via `ZeroSettleConfig` to target your own app. If your deployment requires an Authorization header, provide a closure through `partnerAuthTokenProvider` to return a bearer token at request time.

## Architecture

```
ZeroSettleKit
├── Core/
│   ├── ZeroSettleManager.swift       # Main facade
│   ├── ZeroSettleConfig.swift        # Configuration
│   └── ZeroSettleDelegate.swift      # Event callbacks
│
├── Authentication/
│   └── AuthenticationManager.swift   # Privy integration
│
├── Funding/
│   ├── PaymentProcessor.swift        # Protocol
│   └── Coinbase/
│       ├── CoinbasePaymentProcessor.swift
│       ├── CoinbaseJWTGenerator.swift
│       └── CoinbaseOnrampEventHandler.swift
│
├── Phantom/
│   └── PhantomManager.swift          # Solana wallet deeplinks
│
├── MetaMask/
│   └── MetaMaskManager.swift         # Ethereum wallet integration
│
├── Models/
│   └── BlockchainModels.swift        # Shared models
│
└── UI/ (coming soon)
    └── Components/
```

## Protocol-Based Design

ZeroSettleKit uses protocols to support multiple payment processors:

```swift
public protocol PaymentProcessor {
    var supportedMethods: [PaymentMethod] { get }

    func initiateFunding(
        amount: Decimal,
        currency: String,
        destination: String,
        network: BlockchainNetwork
    ) async throws -> FundingSession
}
```

### Supported Processors

- ✅ **Coinbase Commerce** (Apple Pay, Credit/Debit Cards)
- 🔜 **Stripe** (Coming soon)
- 🔜 **MoonPay** (Coming soon)
- 🔜 **Custom** (Implement your own!)

## Delegate Pattern

Implement `ZeroSettleDelegate` to receive events:

```swift
extension MyViewController: ZeroSettleDelegate {
    func didAuthenticate(userId: String, wallet: WalletInfo) {
        print("✅ User \(userId) authenticated with wallet \(wallet.address)")
    }

    func didCompleteFunding(amount: Decimal, currency: String, transactionHash: String?) {
        print("💰 Added \(amount) \(currency)")
    }

    func didFailFunding(error: Error) {
        print("❌ Funding failed: \(error)")
    }
}
```

## Multi-Chain Support

ZeroSettleKit is designed to support multiple blockchains:

```swift
public enum BlockchainNetwork: String, Codable {
    case ethereum
    case base
    case arbitrum
    case optimism
    case polygon
    case solana
}
```

Currently, Privy SDK supports Solana embedded wallets. EVM chain support coming soon!

## Customization

### Theming

```swift
let theme = ZeroSettleTheme(
    primaryColor: "#00FF00",
    secondaryColor: "#FFFFFF",
    backgroundColors: ["#000000", "#1A1A1A"],
    buttonCornerRadius: 12
)

let config = ZeroSettleConfig(
    ...
    theme: theme
)
```

### Default Funding Amounts

```swift
let config = ZeroSettleConfig(
    ...
    defaultFundingAmounts: [100, 500, 1000, 2000] // Cents: $1, $5, $10, $20
)
```

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15.0+

## Dependencies

- [Privy iOS SDK](https://github.com/privy-io/privy-ios-sdk) (2.5.1+)
- [MetaMask iOS SDK](https://github.com/MetaMask/metamask-ios-sdk) (0.8.10+)
- [TweetNacl](https://github.com/bitmark-inc/tweetnacl-swiftwrap) (1.1.0+) - For Phantom encryption
- [Solana.Swift](https://github.com/your-org/Solana.Swift) - Solana blockchain support

## Getting API Keys

### Privy

1. Sign up at [privy.io](https://privy.io)
2. Create a new app
3. Copy your App ID and Client ID

### Coinbase Commerce

1. Sign up at [Coinbase Developer Platform](https://portal.cdp.coinbase.com/)
2. Create API credentials
3. Copy your API Key ID and Secret

## Security

⚠️ **Never commit API credentials to your repository!**

Use environment variables or a secure configuration:

```swift
// ❌ DON'T do this
let apiKey = "your-secret-key"

// ✅ DO this
let apiKey = ProcessInfo.processInfo.environment["COINBASE_API_KEY"] ?? ""
```

## Wallet Integration Guides

### MetaMask (Ethereum)

See [METAMASK_INTEGRATION.md](METAMASK_INTEGRATION.md) for complete MetaMask integration guide including:
- ETH and ERC-20 token transfers
- USDC support on multiple chains (Ethereum, Polygon, Optimism, Arbitrum)
- Balance queries and chain switching
- Custom JSON-RPC calls

Quick example:

```swift
// Configure MetaMask
MetaMaskManager.shared.configure(
    dappScheme: "yourapp",
    appName: "Your App",
    appURL: "https://yourapp.com",
    infuraAPIKey: "YOUR_INFURA_KEY"
)

// Connect
await MetaMaskManager.shared.connect()

// Send USDC
await MetaMaskManager.shared.sendUSDC(
    to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
    amountUSDC: 5.0
)
```

### Phantom (Solana)

PhantomManager is included for Solana wallet integration via deep links:

```swift
// Configure Phantom
PhantomManager.shared.configure(
    appURL: "https://yourapp.com",
    redirectScheme: "yourapp",
    cluster: .mainnetBeta
)

// Connect
PhantomManager.shared.connect()

// Transfer USDC to Privy wallet
PhantomManager.shared.depositUSDCToPrivyWallet(
    fromTokenAccount: "SOURCE_ATA",
    toTokenAccount: "DEST_ATA",
    amountUSDC: 5.0
)
```

## Example App

See the `Example/` directory for a complete implementation.

## Roadmap

- [x] Core authentication (Privy)
- [x] Coinbase payment processor
- [x] Protocol-based architecture
- [ ] SwiftUI UI components
- [ ] Stripe payment processor
- [ ] EVM chain support
- [ ] Transaction monitoring
- [ ] Balance tracking
- [ ] DocC documentation
- [ ] Unit tests
- [ ] Example app

## License

MIT License - See LICENSE file for details

## Contributing

Contributions welcome! Please read CONTRIBUTING.md first.

## Support

- [Documentation](https://docs.zerosettle.com)
- [GitHub Issues](https://github.com/your-org/ZeroSettleKit/issues)
- [Discord](https://discord.gg/zerosettle)

---

Built with ❤️ by [ZeroSettle](https://zerosettle.com)
