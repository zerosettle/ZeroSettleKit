# Changelog

## 1.3.3 — 2026-05-08

### `OfferTipView` and `ZSOfferManager` — drop required `userId:`

Two 1.3-alignment misses from the original API sweep are patched here. Both surfaces still required an explicit `userId:` parameter even after `ZeroSettle.shared.identify(_:)` had been called, conflicting with the broader 1.3 pattern where user-scoped APIs read from internal state.

- **`OfferTipView`** gains a new no-userId initializer:

  ```swift
  // Before (still compiles, now deprecated):
  OfferTipView(userId: user.id)

  // After:
  OfferTipView()  // reads the active user from ZeroSettle.shared
  ```

  The existing `init(userId:...)` is marked deprecated; it routes to the same backing logic. If `identify(_:)` hasn't run when the new init is called, the manager stays in `.loading`/`.ineligible` and the view body returns an empty placeholder.

- **`ZSOfferManager`'s direct init** is deprecated. The factory `ZeroSettle.shared.offerManager(stripeCustomerId:)` (already present since 1.3.0) is the canonical entry point. The direct init still compiles via `@available(*, deprecated)` for source compatibility — devs see a build-time warning pointing at the factory.

`MigrationTipView` has the same pattern but is left alone because its underlying `ZSMigrationManager` is already class-level deprecated in favor of `ZSOfferManager`. Anyone using `MigrationTipView` is already on the migration path to `OfferTipView`.

### Other changes

- `Configuration.sdkVersion` bumped to `"1.3.3"`.

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

### StoreKit listener fix

`Transaction.updates` is no longer subscribed during `configure(_:)` — the listener now starts on the first non-nil `setActiveUserId(_:)` (i.e., the first `identify(_:)`). Closes a `[configure → identify]` race where Apple-redelivered unfinished transactions were processed with `userId == nil` and got mis-attributed. Apple buffers `Transaction.updates` until the async-for loop consumes them, so deferring the listener doesn't drop transactions. The DEBUG-only `assertionFailure` in the no-userId branch of `handleVerifiedTransaction` is also removed — it crashed legitimate dev relaunches with unfinished transactions even though release-build behavior was already correct.

### Other changes

- The `applePaySetupBehavior` enum's docstrings now describe what 1.3.2 actually does. The 1.3.0 docstring promised an in-sheet "Set up Apple Pay" view + auto-transition to checkout — that polish is deferred to 1.4.0.
- `ApplePayAvailabilityProviding` and `MockApplePayAvailability` are now `internal`. They shipped `public` in 1.3.0 but the singleton has no setter to swap them in, so the public symbols were non-functional externally. Tests inside the SDK still use them via `@testable import`.
- `Configuration.sdkVersion` bumped to `"1.3.2"` so the backend's `X-ZS-SDK-Version` header gating sees the right value.

## 1.3.1 — 2026-04-XX

CocoaPods packaging fix; no runtime behavior change.

## 1.3.0 — 2026-04-XX

Initial Apple Pay availability work. Adds the `applePayAvailability` service, the `applePayUnavailable` / `applePaySetupRequired` error cases, and the `presentApplePaySetup()` helper. See `MIGRATING.md` for the broader 1.3 API migration.
