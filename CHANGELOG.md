# Changelog

## 1.3.2 — 2026-05-07

### Behavior change for Apple-Pay-only merchants

`Configuration.applePaySetupBehavior` is now wired end-to-end. The setting was added in 1.3.0 but no call site read it; both behavior values produced identical observable behavior. As of 1.3.2 the setting actually drives the SDK's response when the merchant is Apple-Pay-only and the device's Wallet has no supported card.

The default — `.presentBuiltInUI` — preserves the 1.3.0/1.3.1 banner behavior (built-in "Set up Apple Pay" CTA) **and** adds a new behavior at imperative entry points: when an Apple-Pay-only checkout is started while the device's Wallet is empty, the SDK now opens the system Wallet setup flow automatically before throwing `ZeroSettleError.applePaySetupRequired` to the caller.

**Migration impact:** if your app already targets an Apple-Pay-only merchant configuration and the SDK is called from a path that didn't previously auto-open Wallet (e.g., `CheckoutSheet.present(from:)`, `WebCheckoutFlow`, or `NativePay.Flow.pay`), buyers will now see the system Wallet sheet appear when their Wallet is empty. Previously these paths threw immediately with no UI side effect. To restore the prior behavior — where the SDK only surfaces the error and your app handles UI itself — set:

```swift
ZeroSettle.shared.configure(.init(
    publishableKey: "...",
    applePaySetupBehavior: .delegateToApp
))
```

`.delegateToApp` also hides the banner CTA on `setupRequired` so your app can render its own affordance.

### Other changes

- The `applePaySetupBehavior` enum's docstrings now describe what 1.3.2 actually does. The 1.3.0 docstring promised an in-sheet "Set up Apple Pay" view + auto-transition to checkout — that polish is deferred to 1.4.0.
- `ApplePayAvailabilityProviding` and `MockApplePayAvailability` are now `internal`. They shipped `public` in 1.3.0 but the singleton has no setter to swap them in, so the public symbols were non-functional externally. Tests inside the SDK still use them via `@testable import`.
- `Configuration.sdkVersion` bumped to `"1.3.2"` so the backend's `X-ZS-SDK-Version` header gating sees the right value.

## 1.3.1 — 2026-04-XX

CocoaPods packaging fix; no runtime behavior change.

## 1.3.0 — 2026-04-XX

Initial Apple Pay availability work. Adds the `applePayAvailability` service, the `applePayUnavailable` / `applePaySetupRequired` error cases, and the `presentApplePaySetup()` helper. See `MIGRATING.md` for the broader 1.3 API migration.
