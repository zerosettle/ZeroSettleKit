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
    .package(url: "https://github.com/zerosettle/ZeroSettleKit", from: "1.3.2")
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
    publishableKey: "zs_pk_live_your_key"
))
```

The publishable key prefix (`zs_pk_test_` vs `zs_pk_live_`) determines sandbox vs live mode — there is no separate `environment` parameter.

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

### 3. Identify the user

After `configure`, call `identify(_:)` once you know who the user is. This is the canonical entry point: it fetches the product catalog, restores entitlements, and starts the StoreKit transaction listener — all in one call. You do **not** need to call `fetchProducts` or `restoreEntitlements` separately on launch.

```swift
// Authenticated user — the common case
let catalog = try await ZeroSettle.shared.identify(.user(
    id: currentUser.id,
    name: currentUser.name,
    email: currentUser.email
))

// Or, no auth system — generates a stable per-install UUID
try await ZeroSettle.shared.identify(.anonymous)

// Or, auth resolves on a later screen — suppresses the no-user warning
try await ZeroSettle.shared.identify(.deferred)
```

### 4. Present checkout

Use the built-in checkout sheet for an embedded experience with Apple Pay:

```swift
.checkoutSheet(
    isPresented: $showCheckout,
    product: product
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
try await ZeroSettle.shared.purchase(productId: "pro_monthly")
```

### 5. Check entitlements

Entitlements unify purchases from both web checkout and StoreKit into a single state. After `identify(_:)` they're already populated:

```swift
let isPro = ZeroSettle.shared.entitlements.contains {
    $0.productId == "pro_monthly" && $0.isActive
}
```

For real-time updates, observe `entitlementUpdates`:

```swift
for await entitlements in ZeroSettle.shared.entitlementUpdates {
    refreshUI(entitlements.filter(\.isActive))
}
```

To force-refresh from the server (e.g., on foreground), call `restoreEntitlements()` — no `userId` parameter once `identify` has run.

## Checkout Modes

The checkout experience is controlled server-side via your dashboard:

| Mode | Description |
|------|-------------|
| **Embedded Sheet** | Native bottom sheet with WKWebView — Apple Pay and card support |
| **In-App Safari** | SFSafariViewController within your app |
| **External Safari** | Opens the user's default browser, returns via universal link |

The SDK reads this configuration automatically — no client-side changes needed to switch modes.

## User Identity

`identify(_:)` takes an `Identity` enum so the SDK can distinguish three states an app can be in at launch:

| Identity case | When to use |
|---------------|-------------|
| `.user(id:name:email:)` | You have an authenticated user. `id` is your stable app user ID (RevenueCat users: pass `Purchases.shared.appUserID`). |
| `.anonymous` | No auth system. SDK generates and persists a stable per-install UUID. |
| `.deferred` | Auth resolves on a later screen. Suppresses the no-user warning until you re-identify. |

Use a stable, non-email identifier for `.user(id:)`. See [User Identity](https://docs.zerosettle.io/iap/user-identity) for details.

## Delegate

Implement `ZeroSettleDelegate` to observe checkout and entitlement events:

```swift
extension AppState: ZeroSettleDelegate {
    func zeroSettleCheckoutDidBegin(productId: String) {
        // Checkout sheet/Safari is opening
    }

    func zeroSettleCheckoutDidComplete(transaction: CheckoutTransaction) {
        // Purchase succeeded — entitlements are already updated
    }

    func zeroSettleCheckoutDidCancel(productId: String) {
        // User dismissed checkout
    }

    func zeroSettleCheckoutDidFail(productId: String, error: Error) {
        // Handle error
    }

    func zeroSettleEntitlementsDidUpdate(_ entitlements: [Entitlement]) {
        // Entitlement state changed (filter on \.isActive for app logic)
    }
}
```

For SwiftUI apps, prefer `entitlementUpdates` (`AsyncStream<[Entitlement]>`) over the delegate — `ZeroSettle.shared` is `@Observable`, so views can also read state directly.

## StoreKit Integration

Offer both web checkout (lower fees) and native StoreKit on the same paywall. After `identify(_:)`, neither call needs a `userId`:

```swift
// Web checkout — 5% + 50¢
try await ZeroSettle.shared.purchase(productId: "pro_monthly")

// StoreKit fallback — standard App Store pricing
let transaction = try await ZeroSettle.shared.purchaseViaStoreKit(productId: "pro_monthly")
```

Both paths feed into the same entitlement system. See [StoreKit Integration](https://docs.zerosettle.io/iap/storekit-integration) for hybrid paywall patterns.

## Universal Links

Web checkout callbacks require universal links. Add an Apple App Site Association file to your domain and configure your entitlements. See [Universal Links Setup](https://docs.zerosettle.io/iap/universal-links-setup) for the full walkthrough.

**Note:** Universal links do not work in the iOS Simulator — test on a physical device.

## Apple External Purchase Compliance (EU / Japan)

In jurisdictions where Apple permits external purchases but still requires reporting (EU/EEA under the DMA alternative terms, EEA music streaming, and Japan under the MSCA), every external sale must be reported to Apple with an external-purchase token. The SDK automates the device-side half of this:

**What the SDK does automatically (no code required):**

- Detects the user's true App Store storefront (`Storefront.current`) and sends it with every checkout, so ZeroSettle attributes the transaction to the correct jurisdiction (not the card billing country).
- Mints an Apple external-purchase token at checkout in eligible regions — `ExternalPurchaseCustomLink.token(for:)` on iOS 18.1+ (`ACQUISITION`, falling back to `SERVICES`; `LINK_OUT` for Japan on iOS 26.4+), or the `ExternalPurchase` notice sheet on iOS 17.4–18.0 in the EEA — and attaches it to the checkout request.
- Degrades gracefully: if the entitlement is missing, the OS is too old, the user cancels the notice sheet, or minting fails for any reason, checkout proceeds without a token. Minting never blocks a purchase.

ZeroSettle's backend decodes the token and submits the required reports to Apple's External Purchase Server API on your behalf.

**What you (the developer) must do — the SDK cannot do this for you:**

1. **Enroll with Apple.** Sign the applicable addendum (EU Alternative Terms Addendum, Japan link-out under the MSCA, or the music-streaming entitlement) and request the external-purchase entitlements for your app.
2. **Add the entitlements to your app target** (entitlements are baked into your app's code signature — a Swift package cannot declare them):
   - `com.apple.developer.storekit.external-purchase-link`
   - `com.apple.developer.storekit.custom-purchase-link.allowed-regions` (for custom-link regions, including Japan)
3. **Add the matching Info.plist keys** (`SKExternalPurchase`, `SKExternalPurchaseLink`, and the `SKExternalPurchaseCustomLinkRegions` / `SKExternalPurchaseLinkStreamingRegions` region lists, as applicable to your enrollment).
4. **Mind the iOS floors.** Link-out external purchases require iOS 17.4+; the custom-link token API the SDK prefers requires iOS 18.1+; Japan token minting requires iOS 26.4+. The SDK handles older versions by simply not minting.
5. **Upload your In-App Purchase key** in the ZeroSettle dashboard and enable Apple reporting so the backend can submit reports.

**Honest fine print:**

- **Commission still applies in the EU and Japan.** External purchases there carry a reduced Apple commission — reporting is what makes Apple's invoice possible. The savings versus standard App Store pricing are real but jurisdiction-dependent.
- **The US requires none of this today.** Post-injunction, US external purchases need no token, no report, and carry no Apple commission. The SDK does not mint in the US.
- **South Korea and the Netherlands are not yet supported** by ZeroSettle's automatic reporting (they use a different entitlement and, for NL, a weekly reporting cadence). If you operate external purchases there, you must report manually for now.

## Key Types

| Type | Description |
|------|-------------|
| `ZeroSettle` | Main SDK singleton — configure, identify, purchase, restore |
| `Identity` | Enum passed to `identify(_:)` — `.user`, `.anonymous`, or `.deferred` |
| `ZSProduct` | A purchasable item with web and App Store pricing |
| `Entitlement` | An active access right with source tracking (`.webCheckout` or `.storeKit`) |
| `CheckoutTransaction` | Result of a completed purchase (formerly `ZSTransaction`) |
| `CheckoutSheet` | SwiftUI checkout sheet component (formerly `ZSPaymentSheet`) |
| `RemoteConfig` | Server-controlled checkout mode and migration campaigns |
| `Promotion` | Active promotional pricing on a product |

## Requirements

- iOS 17.0+
- Swift 5.9+
- Xcode 15.0+
- No third-party dependencies (for ZeroSettleKit)

## Best Practices

- **Call `identify(_:)` on every app launch** — it initializes the SDK and refreshes entitlements in one call
- **Validate entitlements server-side** for sensitive features
- **Provide a visible "Restore Purchases" button** (App Store requirement) — wire it to `restoreEntitlements()`
- **Use sandbox keys during development** — `zs_pk_test_…` for sandbox, `zs_pk_live_…` for production
- **Preload products on paywall screens** for instant checkout (`preloadCheckout: true` in `Configuration`)
- **Never trust client-side entitlements alone** for critical access control

## Migrating from earlier SDK versions

See [`MIGRATING.md`](MIGRATING.md) for the rename matrix and a guide to upgrading from 1.0–1.2 to 1.3.

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
