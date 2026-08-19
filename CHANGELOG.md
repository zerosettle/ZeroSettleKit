# Changelog

## 1.6.0 — unreleased

Additive minor. No breaking changes, and `Configuration` is untouched — no new
fields, no changed defaults — so this is a drop-in upgrade from 1.5.x.

Cut deliberately **without** the in-flight cancel-flow UI work, which stays
unreleased and moves to 1.7.0. This branch is 1.5.2 + the experiments work +
the observer-mode changes below.

> **TODO before tagging:** the experiments work (`checkout_route` routing,
> storefront on products fetch, 410 re-init recovery, variant-aware cache key —
> commits d36c6bd, c8bcea3, 78b7815) is in this release and has no notes here.
> Whoever owns it should add a section; it adds public surface of its own, which
> is part of why this is a minor rather than a patch.

### `recordStoreKitPurchase(_:)`

New public API for apps that run their own `Product.purchase()` and use
ZeroSettle to track the result rather than to sell.

**Optional.** You do not need it if you buy through the SDK (`purchase`,
`purchaseViaStoreKit`, `.checkoutSheet`) — those already sync. Nor for
renewals, refunds, revocations, or purchases made on another device, which
arrive through the `Transaction.updates` listener and the launch reconcile. Nor
at all, if you are content for your own purchase to show up at the next
`identify(_:)` instead of within seconds. It closes exactly one window: an app
that owns its paywall and wants its own sale reported immediately.

`Transaction.updates` does not redeliver a transaction StoreKit already
returned from `Product.purchase()`, so the SDK's listener never saw those
purchases. They were not lost — the next `identify(_:)` sweeps
`Transaction.currentEntitlements` and picks them up — but that could be a whole
app launch away, and there was no way to close the gap.

```swift
let result = try await product.purchase(options: options)
if case .success(.verified(let transaction)) = result {
    await transaction.finish()
    unlock()
    dismiss()
    Task { await ZeroSettle.shared.recordStoreKitPurchase(result) }
}
```

Three overloads: `Product.PurchaseResult`, `VerificationResult<Transaction>`,
and `productId:` (which resolves `Transaction.latest(for:)`). All are
non-throwing and return `Bool` — a failed report is queued by the same
persistent retry queue that backs the listener, and the return value is for
logging, never for gating access. The transaction is **not** finished for you;
an app on this path already owns that.

### `ZeroSettleError` is now `Equatable`

`error == .cancelled` is what adopters keep writing — two samples in our own
docs did — and it did not compile. Synthesis is impossible because several
cases carry an `any Error`; those compare by case identity, while cases with
value-typed payloads compare their payloads. `CheckoutFailureReason` is
`Equatable` too.

`isCancellation(_:)` remains the right tool for cancellations: it also catches
`CancellationError` and StoreKit's `userCancelled`, which `== .cancelled`
cannot see.

### Privacy manifest

`Sources/ZeroSettleKit/PrivacyInfo.xcprivacy`, declared as a `.copy` resource so
it lands at the root of the SDK's resource bundle.

Apple expects third-party SDKs to declare their own required-reason API use and
data collection. Without it, adopters either guessed on our behalf — they cannot
see inside the binary — or shipped without the declaration and collected
ITMS-91053 on upload. RevenueCat has shipped one for a while; we were the odd
one out in the same app.

Declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (the
app-scoped reason — the SDK uses `UserDefaults.standard` exclusively, never an
App Group suite), `NSPrivacyTracking` false with no tracking domains, and four
collected data types: user id, purchase history, and the optional name/email
from `identify(.user(id:name:email:))` / `setCustomer(name:email:)`, plus the
iOS version and App Store storefront that feed jurisdiction detection.

Audited for the rest of the required-reason surface at the same time — no file
timestamps, disk space, boot time, active keyboards, IDFA, or Keychain. If any
of those arrive, or a shared App Group suite does, this file has to change with
them.

### `objectWillChange` now fires on every observable mutation

`ZeroSettle` is both `@Observable` and `ObservableObject`, and the macro does
not publish to `objectWillChange`. Only `entitlements` and `pendingClaims` were
sending manually, so any view reading `ZeroSettle.shared` through
`@ObservedObject` / `@StateObject` silently missed changes to `products`,
`pendingCheckout`, `isConfigured`, `currentOffer`, and the entitlements reset
inside `identify(_:)`.

A product list bound that way never re-rendered when the catalog loaded, and a
spinner bound to `pendingCheckout` never moved. The 16 `pendingCheckout`
assignment sites now route through one mutator so a new one cannot silently
forget.

`@Observable` tracking — reading `ZeroSettle.shared` directly in a SwiftUI
`body` — was never affected and remains the recommended style.

This is the one behavioural change in the release. It is a fix, but it is
visible: an `ObservableObject` consumer starts receiving updates it was
previously missing, so a view that appeared static may now re-render where it
did not before.

## 1.5.0 — 2026-06-01

On-screen offer-impression tracking:
- `ZeroSettle.reportOfferViewed(productId:variantId:flowType:)` — low-level fire-and-forget impression report.
- `.offerImpression()` SwiftUI view modifier and `OfferImpressionInteraction` (UIKit) — attach to any banner to report a ≥50%-on-screen impression once per session; auto-resolve the active offer via the new `ZeroSettle.currentOffer`.
- `OfferTipView` now reports its own impressions through the modifier.

## 1.3.6 — 2026-05-11

Fixes checkout sheet shrink-mid-presentation on the UIKit static `CheckoutSheet.present(...)` path. Adopters using the SwiftUI `.checkoutSheet(item:)` modifier with `preload:` pre-warming are not affected.

### What was wrong

`CheckoutPreloaderPool.ensureReady` returned the moment `buttonsReady` fired (Stripe payment buttons interactive), but `measuredContentHeight` is set later — when `measureContentJS` completes and `isReady` flips. When the sheet animated open during this gap, `CheckoutSheet`'s internal init read `measuredContentHeight = 0`, the WebView frame fell back to a hardcoded 300pt placeholder, then the live geometry observer fired with the real (typically smaller) height and the sheet visibly shrank.

### Fix

`ensureReady` now waits for both `buttonsReady` AND `isReady`. The internal init reads a non-zero `measuredContentHeight` from the start; the WebView mounts at the correct height; the sheet doesn't resize on first present.

Trade-off: ~200-500ms additional cold-start latency between CTA tap and sheet animation. Pre-warmed adopters (modifier path with `preload:`) see no latency change — `isReady` is already true by the time `ensureReady` is called.

### Internals

- New `waitForReady() async -> Bool` on `CheckoutPreloader` (mirrors `waitForButtonsReady`).
- `CheckoutPreloaderPool.ensureReady` extends its wait to include the `isReady` signal.

### Adopters affected

- UIKit-static adopters calling `CheckoutSheet.present(from:product:...)` directly.
- Flutter adopters via `ZeroSettle.instance.presentPaymentSheet(productId:)`.

### Bumps

- (No external dependency bumps in this release.)

## 1.3.5 — 2026-05-11

Auto-bookkeeping for `ZSOfferManager` checkouts. The migration/upgrade flow no longer requires adopters to call `manager.present()` and `manager.markCheckoutSucceeded()` manually — the SDK detects active offer context and runs the state machine automatically when you use any standard purchase entry point.

### What's new

The three Kit choke points (`CheckoutSheet.present(...)`, `.checkoutSheet(item:)` SwiftUI modifier, and `ZeroSettle.shared.purchase(...)`) now consult `ZeroSettle.shared.offerManager()` and run the offer state machine when the productId matches the active offer's `checkoutProductId`:

- Pre-checkout: state advances `.eligible → .presented` (replacing `manager.present()`).
- Post-checkout success: state advances `.presented → .accepted` or `.presented → .completed` based on `needsAppleCancel`. Conversion analytics fire for `flowType == .migration` and `upgradeType == .storekitToWeb`.
- Failure / cancellation: state stays at `.presented`. Adopter retries by tapping the CTA again.

Adopters using `.checkoutSheet(item: $product)` (the JustOne pattern) stop needing the `manager.markCheckoutSucceeded()` callback in their `onComplete`. Reactive `stateUpdates` listeners see the transitions arrive automatically.

### Deprecations

- `ZSOfferManager.present()` — `@available(*, deprecated)`. Bookkeeping is automatic.
- `ZSOfferManager.markCheckoutSucceeded(transactionId:)` — `@available(*, deprecated)`. Bookkeeping is automatic. Body retained through 1.x for raw-URL escape-hatch adopters using `startCheckout`.

Both will be removed in 2.0.

### Not deprecated

- `ZSOfferManager.startCheckout(stripeCustomerId:checkoutMode:)` — remains the sanctioned path for adopters who need custom WebView/transport. Docstring rewritten to clarify scope.

### Behavioral note for legacy adopters

`markCheckoutSucceeded(transactionId:)`'s body now performs `verifyTransaction → delegate.zeroSettleCheckoutDidComplete → refreshEntitlementsAfterCheckout` BEFORE the offer state transition (previously: state transition first, then verify chain). This aligns the legacy method's ordering with the auto-path's ordering — `CheckoutSheet.present` runs verify+delegate+refresh internally before any offer bookkeeping fires. If your `zeroSettleCheckoutDidComplete` delegate callback reads `manager.state` synchronously, it will now see `.presented` instead of `.accepted`/`.completed`. Read state from your callback after the manager publishes the state transition (via `@Published` or after `markCheckoutSucceeded` returns) to see the post-bookkeeping value.

### Internals

- New `OfferCheckoutBookkeeping` helper (`armOfferForCheckoutIfApplicable`, `applyOfferCheckoutCompletionIfApplicable`) — single source of truth for the auto-path.
- New `_armForCheckout(source:)` and `_applyCheckoutCompletion(transactionId:source:)` on `ZSOfferManager`. Existing public methods delegate.
- New `ZeroSettle.shared._activeOfferManagerForBookkeeping` — non-instantiating peek at the cached manager. Adopters who never use offers pay zero cost (single nil check at the choke points).

### Migration

JustOne and similar adopters with `manager.present()` + `manager.markCheckoutSucceeded()` calls around their `.checkoutSheet`: delete both calls. The SDK now handles them. Compile-time deprecation warnings will guide you.

Adopters using `manager.startCheckout()` for raw URL flows: no change — that path stays manual and supported.

### Compatibility

Source-compatible. Adopters who don't change anything keep working through compile-time deprecation warnings.

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
