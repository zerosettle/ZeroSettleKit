# ZeroSettleKit

A Swift SDK that lets iOS developers offer web-based checkout as an alternative to In-App Purchase — keeping more revenue while staying fully compliant with App Store guidelines.

**5% + 50¢ per transaction. Instant Stripe payouts. We handle tax, compliance, and liability as your Merchant of Record.**

[Documentation](https://docs.zerosettle.io) · [Dashboard](https://zerosettle.io)

---

## Why ZeroSettle

On a $9.99 sale through the App Store, you keep ~$6.99. With ZeroSettle, you keep ~$8.99.

ZeroSettle acts as your **Merchant of Record** — we're the legal seller, so we handle sales tax remittance, chargebacks, refunds, and regulatory compliance. You focus on building your app.

- **Web checkout with Apple Pay** — Stripe-powered payment sheet that feels native
- **StoreKit 2 integration** — offer both web and App Store pricing on the same paywall
- **Entitlement management** — unified subscription state across both purchase sources
- **Server-controlled checkout** — embedded sheet, in-app Safari, or external Safari
- **Tax compliance** — US sales tax, EU VAT, and AU GST handled automatically
- **Promotional pricing** — percent off, fixed amount, and free trial support

## Products

ZeroSettleKit ships two independent products you can import separately:

| Product | Import | Purpose |
|---------|--------|---------|
| **ZeroSettleKit** | `import ZeroSettleKit` | Merchant of Record web checkout for subscriptions and one-time purchases |
| **ZeroSettleEscrow** | `import ZeroSettleEscrow` | Skill-based competitive gaming with on-chain Solana escrow |

This README covers **ZeroSettleKit**. For Escrow documentation, see [docs.zerosettle.io](https://docs.zerosettle.io).

## Installation

### Swift Package Manager

Add ZeroSettleKit to your project in Xcode:

1. File > Add Package Dependencies...
2. Enter: `https://github.com/zerosettle/ZeroSettleKit`
3. Add `ZeroSettleKit` to your target

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zerosettle/ZeroSettleKit", from: "1.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "ZeroSettleKit", package: "ZeroSettleKit")
        ]
    )
]
```

## Quick Start

### 1. Configure the SDK

Call `configure` early in your app lifecycle — typically in your `App` init or `AppDelegate`:

```swift
import ZeroSettleKit

ZeroSettle.shared.configure(.init(
    publishableKey: "pk_live_your_key",
    environment: .production,
    syncStoreKitTransactions: true
))
```

### 2. Attach the handler

Add the universal link handler to your root view so checkout callbacks are processed:

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .zeroSettleHandler()
        }
    }
}
```

### 3. Fetch products

Products are defined in the [ZeroSettle Dashboard](https://zerosettle.io) and include both web pricing and App Store pricing:

```swift
let products = try await ZeroSettle.shared.fetchProducts(userId: user.id)

for product in products {
    print("\(product.displayName): \(product.webPrice.formatted)")
}
```

### 4. Present checkout

Use the built-in payment sheet for an embedded checkout experience with Apple Pay:

```swift
.zsPaymentSheet(
    isPresented: $showCheckout,
    product: product,
    userId: user.id
) { result in
    switch result {
    case .success(let transaction):
        // Entitlements update automatically
        unlockContent(transaction.productId)
    case .failure(let error):
        showError(error)
    }
}
```

Or trigger a Safari-based checkout directly:

```swift
try await ZeroSettle.shared.purchase(
    productId: "pro_monthly",
    userId: user.id
)
```

### 5. Check entitlements

Entitlements unify purchases from both web checkout and StoreKit into a single state:

```swift
let entitlements = try await ZeroSettle.shared.restoreEntitlements(userId: user.id)

let isPro = entitlements.contains { $0.productId == "pro_monthly" && $0.isActive }
```

Call `restoreEntitlements` on every app launch to ensure cross-device sync.

## Checkout Modes

The checkout experience is controlled server-side via your dashboard:

| Mode | Description |
|------|-------------|
| **Embedded Sheet** | Native bottom sheet with WKWebView — Apple Pay and card support |
| **In-App Safari** | SFSafariViewController within your app |
| **External Safari** | Opens the user's default browser, returns via universal link |

The SDK reads this configuration automatically — no client-side changes needed to switch modes.

## User Identity

ZeroSettleKit works with any authentication system:

| Approach | When to use | userId value |
|----------|-------------|--------------|
| **Custom Auth** | You have your own auth system | Your stable user ID |
| **RevenueCat** | Migrating from RevenueCat | `Purchases.shared.appUserID` |
| **Anonymous** | No auth system | Empty string (email collected at checkout) |

Use a stable, non-email identifier. See [User Identity](https://docs.zerosettle.io/iap/user-identity) for details.

## Delegate

Implement `ZeroSettleDelegate` to observe checkout and entitlement events:

```swift
extension AppState: ZeroSettleDelegate {
    func zeroSettleCheckoutDidComplete(transaction: ZSTransaction) {
        // Purchase succeeded — entitlements are already updated
    }

    func zeroSettleCheckoutDidCancel(productId: String) {
        // User dismissed checkout
    }

    func zeroSettleCheckoutDidFail(productId: String, error: Error) {
        // Handle error
    }

    func zeroSettleEntitlementsDidUpdate(_ entitlements: [Entitlement]) {
        // Entitlement state changed
    }
}
```

## StoreKit Integration

Offer both web checkout (lower fees) and native StoreKit on the same paywall:

```swift
// Web checkout — 5% + 50¢
try await ZeroSettle.shared.purchase(
    productId: "pro_monthly",
    userId: user.id
)

// StoreKit fallback — standard App Store pricing
let transaction = try await ZeroSettle.shared.purchaseViaStoreKit(
    productId: "pro_monthly",
    userId: user.id
)
```

Both paths feed into the same entitlement system. See [StoreKit Integration](https://docs.zerosettle.io/iap/storekit-integration) for hybrid paywall patterns.

## Universal Links

Web checkout callbacks require universal links. Add an Apple App Site Association file to your domain and configure your entitlements. See [Universal Links Setup](https://docs.zerosettle.io/iap/universal-links-setup) for the full walkthrough.

**Note:** Universal links do not work in the iOS Simulator — test on a physical device.

## Key Types

| Type | Description |
|------|-------------|
| `ZeroSettle` | Main SDK singleton — configure, fetch, purchase, restore |
| `ZSProduct` | A purchasable item with web and App Store pricing |
| `Entitlement` | An active access right with source tracking (`.webCheckout` or `.storeKit`) |
| `ZSTransaction` | Result of a completed purchase |
| `ZSPaymentSheet` | SwiftUI payment sheet component |
| `RemoteConfig` | Server-controlled checkout mode and migration campaigns |
| `Promotion` | Active promotional pricing on a product |

## Requirements

- iOS 17.0+
- Swift 5.9+
- Xcode 15.0+
- No third-party dependencies (for ZeroSettleKit)

## Best Practices

- **Call `restoreEntitlements` on every app launch** for cross-device sync
- **Validate entitlements server-side** for sensitive features
- **Provide a visible "Restore Purchases" button** (App Store requirement)
- **Use sandbox keys during development** — switch to live keys for production
- **Preload products on paywall screens** for instant checkout
- **Never trust client-side entitlements alone** for critical access control

See [Best Practices](https://docs.zerosettle.io/iap/best-practices) for the full guide.

## Documentation

Full guides, API reference, and integration walkthroughs are available at **[docs.zerosettle.io](https://docs.zerosettle.io)**.

- [Quickstart](https://docs.zerosettle.io/iap/quickstart)
- [Payment Sheet](https://docs.zerosettle.io/iap/payment-sheet)
- [User Identity](https://docs.zerosettle.io/iap/user-identity)
- [Subscription State](https://docs.zerosettle.io/iap/subscription-state)
- [StoreKit Integration](https://docs.zerosettle.io/iap/storekit-integration)
- [RevenueCat Integration](https://docs.zerosettle.io/iap/revenuecat-integration)
- [Cancel Flow](https://docs.zerosettle.io/iap/cancel-flow)
- [Best Practices](https://docs.zerosettle.io/iap/best-practices)

## License

MIT License — see LICENSE for details.
