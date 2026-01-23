# Architecture

Understand how ZeroSettleKit is designed and structured.

## Overview

ZeroSettleKit follows a modular, protocol-oriented architecture that makes it easy to understand, extend, and test. The framework is divided into several key layers, each with a specific responsibility.

## Core Components

### ZeroSettleManager

The main facade that coordinates all ZeroSettleKit functionality. This is your primary interaction point with the framework.

```swift
let manager = ZeroSettleManager(config: config)
await manager.initialize()
```

**Responsibilities:**
- Coordinates authentication, payments, and wallet operations
- Manages application state
- Provides SwiftUI-friendly published properties
- Delegates to specialized managers for specific tasks

### AuthenticationManager

Handles all user authentication via Privy SDK.

**Responsibilities:**
- Phone number authentication with OTP
- Embedded wallet creation and management
- Session management and token refresh
- Secure storage of authentication state

### PaymentProcessor Protocol

Defines the interface for payment processing. ZeroSettleKit includes ``CoinbasePaymentProcessor`` out of the box, but you can implement your own.

```swift
protocol PaymentProcessor {
    func startPayment(amount: Double, currency: String) async throws -> FundingSession
    func getPaymentStatus(sessionId: String) async throws -> PaymentStatus
    func cancelPayment(sessionId: String) async throws
}
```

**Responsibilities:**
- Converting fiat to crypto
- Managing payment sessions
- Monitoring payment status
- Handling payment callbacks

### WalletManager

Manages blockchain wallet operations.

**Responsibilities:**
- Querying wallet balances
- Preparing transactions
- Signing and submitting transactions
- Multi-chain support

## Data Flow

### Authentication Flow

```
User → ZeroSettleManager → AuthenticationManager → Privy SDK
                                    ↓
                            Embedded Wallet Created
                                    ↓
                              Wallet Address
                                    ↓
                           WalletManager (monitors balance)
```

### Payment Flow

```
User initiates payment → ZeroSettleManager
            ↓
    PaymentProcessor.startPayment()
            ↓
    Coinbase Commerce session created
            ↓
    User completes Apple Pay
            ↓
    USDC deposited to wallet
            ↓
    PayoutTable distributes funds (if configured)
            ↓
    Balance updated
```

### Payout Distribution

```
Payment received → ZeroSettleManager checks payout table
                         ↓
                  Calculate split amounts
                         ↓
                 WalletManager prepares transactions
                         ↓
                 AuthenticationManager signs transactions
                         ↓
                 Transactions submitted to blockchain
                         ↓
                 Recipients receive funds
```

## Module Organization

### Core

Contains the fundamental types and protocols:
- ``ZeroSettleManager``
- ``ZeroSettleConfig``
- ``ZeroSettleDelegate``
- Error types

### Authentication

Everything related to user authentication:
- ``AuthenticationManager``
- Privy SDK integration
- Wallet creation

### Funding

Payment processing components:
- ``PaymentProcessor`` protocol
- ``CoinbasePaymentProcessor``
- ``FundingSession``

### Wallet

Blockchain wallet operations:
- Balance querying
- Transaction signing
- Multi-chain support

### Models

Shared data types:
- ``WalletInfo``
- ``TransactionReceipt``
- ``PayoutTier``
- ``ZeroSettlePayoutTable``

### UI (Optional)

Pre-built SwiftUI components:
- Balance displays
- Payment buttons
- Authentication views

## Design Patterns

### Protocol-Oriented Design

ZeroSettleKit uses protocols extensively to enable flexibility and testability:

```swift
// Easy to mock for testing
class MockPaymentProcessor: PaymentProcessor {
    func startPayment(amount: Double, currency: String) async throws -> FundingSession {
        // Return test data
    }
}

// Easy to extend with custom implementations
class StripePaymentProcessor: PaymentProcessor {
    // Your custom Stripe integration
}
```

### Dependency Injection

All dependencies are injected through ``ZeroSettleConfig``:

```swift
let config = ZeroSettleConfig(
    privyAppId: "...",
    coinbaseApiKey: "...",
    customPaymentProcessor: MyCustomProcessor(), // Optional
    customNetworkProvider: MyNetworkProvider()   // Optional
)
```

### Async/Await

All asynchronous operations use Swift's modern concurrency:

```swift
// Clean, readable async code
try await manager.authenticate()
let session = try await manager.startPayment(amount: 10.0)
try await session.waitForCompletion()
```

### Actor-Based Concurrency

Critical components use actors to prevent data races:

```swift
actor WalletManager {
    private var cachedBalance: Double?

    func getBalance() async throws -> Double {
        // Thread-safe balance access
    }
}
```

## State Management

### Observable State

``ZeroSettleManager`` publishes state changes for SwiftUI:

```swift
@Published var isAuthenticated: Bool
@Published var walletBalance: Double?
@Published var currentUser: UserInfo?
```

### Event Delegation

For more complex state management, implement ``ZeroSettleDelegate``:

```swift
extension MyClass: ZeroSettleDelegate {
    func zeroSettle(_ manager: ZeroSettleManager,
                    didUpdateBalance balance: Double) {
        // Handle balance updates
    }

    func zeroSettle(_ manager: ZeroSettleManager,
                    didReceivePayment payment: PaymentEvent) {
        // Handle incoming payments
    }
}
```

## Error Handling

ZeroSettleKit uses typed errors for better error handling:

```swift
do {
    try await manager.authenticate()
} catch AuthenticationError.invalidPhoneNumber {
    // Handle invalid phone number
} catch AuthenticationError.otpExpired {
    // Handle expired OTP
} catch {
    // Handle other errors
}
```

## Threading Model

### Main Actor

UI-facing components run on the main actor:

```swift
@MainActor
class ZeroSettleManager: ObservableObject {
    // All state updates happen on main thread
}
```

### Background Operations

Heavy operations run on background threads:

```swift
Task.detached {
    // Blockchain operations
    let balance = try await wallet.fetchBalance()

    // Update UI on main thread
    await MainActor.run {
        self.balance = balance
    }
}
```

## Security Architecture

### Key Storage

- Authentication tokens stored in Keychain
- Private keys managed by Privy (embedded wallets)
- API keys never exposed to client code

### Transaction Signing

All transactions are signed locally:

```swift
// Transaction never leaves the device unsigned
let prepared = try await wallet.prepareTransaction(...)
let signed = try await authManager.sign(prepared)
let receipt = try await wallet.submit(signed)
```

## Extension Points

ZeroSettleKit is designed to be extended:

### Custom Payment Processors

Implement ``PaymentProcessor`` to add new payment methods:

```swift
class MyPaymentProcessor: PaymentProcessor {
    func startPayment(amount: Double, currency: String) async throws -> FundingSession {
        // Your payment logic
    }
}

let config = ZeroSettleConfig(
    privyAppId: "...",
    customPaymentProcessor: MyPaymentProcessor()
)
```

### Custom Blockchain Networks

Add support for new blockchains:

```swift
extension BlockchainNetwork {
    static let myCustomChain = BlockchainNetwork(
        name: "My Chain",
        chainId: 12345,
        rpcUrl: "https://rpc.mychain.com"
    )
}
```

## Testing Strategy

The architecture makes testing straightforward:

### Unit Testing

Mock individual components:

```swift
let mockAuth = MockAuthenticationManager()
let mockPayment = MockPaymentProcessor()
let manager = ZeroSettleManager(
    authManager: mockAuth,
    paymentProcessor: mockPayment
)
```

### Integration Testing

Test with real services in sandbox mode:

```swift
let config = ZeroSettleConfig(
    privyAppId: testAppId,
    coinbaseApiKey: testApiKey,
    environment: .sandbox
)
```

## Performance Considerations

### Caching

Frequently accessed data is cached:

```swift
// Balance cached for 30 seconds
let balance = try await manager.walletBalance
```

### Lazy Loading

Components initialize only when needed:

```swift
// Wallet manager created only after authentication
private lazy var walletManager = WalletManager(...)
```

### Request Batching

Multiple balance checks are batched:

```swift
// Multiple calls within 100ms batched into one request
try await manager.refreshBalance()
```

## Next Steps

- <doc:CustomPaymentProcessors> - Build your own payment processor
- <doc:MultiChainSupport> - Add support for new blockchains
- <doc:Security> - Security best practices

## See Also

- ``ZeroSettleManager``
- ``PaymentProcessor``
- ``ZeroSettleDelegate``
- ``ZeroSettleConfig``
