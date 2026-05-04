# Migrating ZeroSettleKit

This guide covers upgrading consumer apps between major API revisions of ZeroSettleKit. The current SDK version is **1.3.0**.

---

## Migrating to 1.3 (from 1.0–1.2)

The 1.3 line introduces a single canonical entry point — `identify(_:)` — and **deprecates every public API that took a `userId` parameter inline**. The deprecated overloads remain compilable through 1.x but will be removed in **2.0**.

### TL;DR

```swift
// 1. Configure once, at launch
ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_live_..."))

// 2. Identify once — fetches catalog, restores entitlements,
//    syncs StoreKit transactions, all in one call
try await ZeroSettle.shared.identify(.user(
    id: currentUser.id,
    name: currentUser.name,
    email: currentUser.email
))

// 3. Call every other API without a userId
try await ZeroSettle.shared.purchase(productId: "pro_monthly")
try await ZeroSettle.shared.restoreEntitlements()
try await ZeroSettle.shared.cancelSubscription(productId: "pro_monthly")
```

`identify(_:)` is sticky — call it once on launch (and again after sign-in/sign-out). Subsequent user-scoped calls read the identified userId from internal state.

### Why the change

Before 1.3, every method that needed a userId took it as a parameter. This caused three real problems:

1. **Drift.** Apps would call `bootstrap(userId: A)` then later `restoreEntitlements(userId: B)` and the SDK would silently switch context, attributing purchases to the wrong account.
2. **Boilerplate.** Every call site had to plumb `userId` through. SwiftUI views especially ended up with `userId: appAuth.appleUserID ?? ""` everywhere.
3. **Anonymous purchases were awkward.** "No userId" meant passing `nil` or `""`, with different semantics depending on the call.

The 1.3 API solves all three: the SDK owns the identity, the call sites get terser, and `Identity.anonymous` is a first-class state.

### Rename matrix

#### `bootstrap` → `identify(_:)`

```diff
- try await ZeroSettle.shared.bootstrap(userId: id, name: name, email: email)
+ try await ZeroSettle.shared.identify(.user(id: id, name: name, email: email))
```

`bootstrap()` is a deprecated alias kept for source compatibility. The new API takes an `Identity` enum so anonymous and deferred-auth states are explicit:

```swift
// No authenticated user — generates a stable per-install UUID
try await ZeroSettle.shared.identify(.anonymous)

// Auth resolves on a later screen — suppresses the no-user warning
try await ZeroSettle.shared.identify(.deferred)
```

#### Drop `userId:` from these methods

After `identify(_:)`, the following all have `userId`-less forms. The deprecated overloads still compile but will be removed in 2.0:

| Old (deprecated) | New |
|---|---|
| `restoreEntitlements(userId: id)` | `restoreEntitlements()` |
| `fetchTransactionHistory(userId: id)` | `fetchTransactionHistory()` |
| `presentCancelFlow(productId: p, userId: id)` | `presentCancelFlow(productId: p)` |
| `acceptSaveOffer(productId: p, userId: id)` | `acceptSaveOffer(productId: p)` |
| `pauseSubscription(productId: p, userId: id, pauseDurationDays: d)` | `pauseSubscription(productId: p, pauseDurationDays: d)` |
| `resumeSubscription(productId: p, userId: id)` | `resumeSubscription(productId: p)` |
| `cancelSubscription(productId: p, userId: id, immediate: i)` | `cancelSubscription(productId: p, immediate: i)` |
| `presentUpgradeOffer(productId: p, userId: id)` | `presentUpgradeOffer(productId: p)` |
| `fetchUpgradeOfferConfig(productId: p, userId: id)` | `fetchUpgradeOfferConfig(productId: p)` |
| `fetchUserOffer(userId: id)` | `fetchUserOffer()` |
| `trackMigrationConversion(userId: id)` | `trackMigrationConversion()` |
| `migrationManager(for: id, stripeCustomerId: cid)` | `migrationManager(stripeCustomerId: cid)` |
| `offerManager(for: id, stripeCustomerId: cid)` | `offerManager(stripeCustomerId: cid)` |

#### `claimEntitlement` → `transferStoreKitOwnershipToCurrentUser`

```diff
- try await ZeroSettle.shared.claimEntitlement(productId: "pro_monthly", userId: id)
+ try await ZeroSettle.shared.transferStoreKitOwnershipToCurrentUser(productId: "pro_monthly")
```

The old name was misleading: it's a destructive ownership transfer, not a lookup. The new name spells out what it does — it changes which ZeroSettle account owns a StoreKit purchase.

#### Renamed type aliases (deprecated)

| Old | New |
|---|---|
| `ZSTransaction` | `CheckoutTransaction` |
| `ZSError` | `ZeroSettleError` |
| `ZSPaymentSheet` | `CheckoutSheet` |
| `MigrationManager` | `ZSMigrationManager` |
| `ZSMigrateTipView` | `MigrationTipView` |
| `ZSManageSubscriptionSheet` | `RetentionSheet` |
| `ZSManageSubscriptionResult` | `RetentionResult` |

#### Renamed view modifiers (deprecated)

| Old | New |
|---|---|
| `.zsPaymentSheet(...)` | `.checkoutSheet(...)` |
| `.zsManageSubscriptionSheet(...)` | `.retentionSheet(...)` |
| `.zsCancelFlow(...)` | `.cancelFlow(...)` |
| `.zsUpgradeOffer(...)` | `.upgradeOffer(...)` |

---

## Watch out: silent breakage of `ZeroSettleDelegate` methods

`ZeroSettleDelegate` provides default empty implementations for every method. That means **renames of delegate method signatures don't produce compile errors** — your old method becomes dead code, and the SDK silently never calls it.

If you have a class that conforms to `ZeroSettleDelegate`, **grep your codebase for the old method names** and rename them:

| Pre-1.0 name | Current name |
|---|---|
| `zeroSettleDidPresentCheckout(productId:)` | `zeroSettleCheckoutDidBegin(productId:)` |
| `zeroSettleDidDismissCheckout(productId:)` | `zeroSettleCheckoutDidCancel(productId:)` |
| `zeroSettleDidCompleteCheckout(productId:)` | `zeroSettleCheckoutDidComplete(transaction:)` (now takes `CheckoutTransaction`) |
| `zeroSettleDidFailCheckout(productId:error:)` | `zeroSettleCheckoutDidFail(productId:error:)` |
| `zeroSettleIAPCheckoutDidBegin(productId:)` | `zeroSettleCheckoutDidBegin(productId:)` |
| `zeroSettleIAPCheckoutDidComplete(transaction:)` | `zeroSettleCheckoutDidComplete(transaction:)` |
| `zeroSettleIAPCheckoutDidCancel(productId:)` | `zeroSettleCheckoutDidCancel(productId:)` |
| `zeroSettleIAPCheckoutDidFail(productId:error:)` | `zeroSettleCheckoutDidFail(productId:error:)` |
| `zeroSettleIAPEntitlementsDidUpdate(_:)` | `zeroSettleEntitlementsDidUpdate(_:)` |
| `zeroSettleIAPDidSyncStoreKitTransaction(productId:transactionId:)` | `zeroSettleDidSyncStoreKitTransaction(productId:transactionId:)` |
| `zeroSettleIAPStoreKitSyncFailed(error:)` | `zeroSettleStoreKitSyncFailed(error:)` |

Quick grep to find dead delegate code:

```bash
git grep -nE "zeroSettleDid(Present|Dismiss|Complete|Fail)Checkout|zeroSettleIAP"
```

If anything matches, those methods are no longer being invoked. Rename them and verify by setting a breakpoint in `zeroSettleCheckoutDidComplete(transaction:)`.

---

## Anonymous purchases

Pre-1.3 apps that supported anonymous purchases by passing `""` or `nil` as `userId` should now use `Identity.anonymous`:

```swift
try await ZeroSettle.shared.identify(.anonymous)
```

The SDK generates a UUID on first call and persists it under `UserDefaults` key `zerosettle.anonymous_session_uuid`. The same UUID is reused across launches until `logout()` is called or the app is uninstalled. Anonymous purchases attach to this UUID and can be reconciled into a real user account later by calling `identify(.user(id: realUserId, ...))`.

---

## Questions or trouble?

- File an issue: <https://github.com/zerosettle/ZeroSettleKit/issues>
- Docs: <https://docs.zerosettle.io>
