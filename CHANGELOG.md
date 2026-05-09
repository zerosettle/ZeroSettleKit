# Changelog

## 1.3.4 — 2026-05-08

### `ApplePayAvailability` migrated to `@Observable`

`ApplePayAvailability` (and its mock) now uses Swift's modern Observation framework instead of `ObservableObject` / `@Published`. SwiftUI consumers can read `state` directly inside view bodies — change tracking is automatic. The internal banner views (`OfferTipView`, `MigrationTipView`) drop their local `@State applePayState` mirror and `.onReceive(...)` block as a result.

Combine compatibility: `statePublisher` is preserved as a deprecated `AnyPublisher<State, Never>` backed by a `CurrentValueSubject` mirror. Combine consumers (e.g., the Flutter wrapper bridge) keep working with a build-time deprecation warning during the migration window. Will be removed in 2.0.

### `OfferTipView` orphan-manager hazard fixed

Pre-1.3.4, constructing `OfferTipView` before `ZeroSettle.shared.identify(_:)` had run created a fresh, dormant `ZSOfferManager` keyed on an empty user id. The view's `@ObservedObject` bound to that orphan permanently and never observed the real shared manager once `identify(_:)` completed — meaning a banner constructed at app launch would silently fail to react to subsequent identification.

Fix:

- `ZeroSettle.shared.offerManager(stripeCustomerId:)` is now non-throwing and eager. It returns a single shared instance regardless of `identify(_:)` state.
- `ZSOfferManager.userId` is now `private(set) var`, with a new internal `setActiveUserId(_:)` that re-evaluates eligibility in place. Existing `@ObservedObject` references stay live across `identify(_:)`.
- `OfferTipView` drops its `?? ZSOfferManager(...)` fallback entirely; the new no-userId initializer (added in 1.3.3) is now reliable in all paths.

`MigrationTipView` is intentionally left on the original unconditional-tear-down path — `ZSMigrationManager` is class-level deprecated in favor of `ZSOfferManager`, so anyone using `MigrationTipView` is already on the migration path.

### `ZeroSettleError.applePaySetupRequired` gains an `autoPresentedSetup: Bool` payload

When the SDK auto-opens the system Wallet setup flow (because `Configuration.applePaySetupBehavior == .presentBuiltInUI`, the default), the error now carries `autoPresentedSetup: true`. In that case `errorDescription` returns `nil` so naive `error.localizedDescription` consumers don't double-stack UI on top of the system sheet the SDK already presented. With `.delegateToApp` the flag is `false` and `errorDescription` returns the human-readable message — your app owns setup UX.

**Source-breaking, but practically harmless — 1.3.0's release of this case has no production adopters yet.** Pattern matches against the bare case need to add `(_)`:

```diff
- case .applePaySetupRequired:
+ case .applePaySetupRequired(_):
```

Or destructure the flag to react to which path the SDK took:

```swift
case .applePaySetupRequired(let autoPresentedSetup):
    if !autoPresentedSetup {
        // SDK didn't auto-open Wallet — show your own setup affordance
        showCustomSetupSheet()
    }
    // If autoPresentedSetup == true, Wallet is already open. No-op or analytics only.
```

### Other changes

- `Configuration.sdkVersion` bumped to `"1.3.4"`.
- The deprecation message on the `migrationManager` stored property now points at `offerManager(stripeCustomerId:)` (the previous fix-it pointed to a now-deprecated overload).
- The unused `private let userId: String?` storage on `OfferTipView` from the 1.3.3 deprecation dance is removed; the deprecated `init(userId:...)` now delegates to the no-args init after a defensive `setActiveUserId(_:)` call.

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
