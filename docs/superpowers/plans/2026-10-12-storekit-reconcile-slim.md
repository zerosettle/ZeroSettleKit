# Slim the StoreKit state reconcile payload

Date: 2026-10-12. Repo: ZeroSettleKit (iOS). Branch `polish/recon-slim`.

## Problem

`SubscriptionStateReconciler.gather()` sends one entry for every transaction in
`Transaction.all`, each about 11KB (signed transaction plus the group's signed
renewal info). A subscriber with a long history sends hundreds of entries on
every launch and after every `Transaction.updates` event. A JustOne sandbox
account sent 2.76MB in one sync and stalled the 512MB staging API.

The backend uses none of that history:
- `api/services/subscription_state_reconcile.py` only emits lifecycle events
  (REVOKED, EXPIRED, GRACE_PERIOD, PAST_DUE, RENEWED) on an existing
  `EntitlementState`, looked up by `originalTransactionId`. It creates no
  `Transaction` rows.
- Every entry for one OTID carries the same renewal info. The staleness gate
  keys on the renewal info `signedDate`, so the first entry per OTID is
  evaluated and every later one is skipped as `stale_signed_date`.
- Prod logs (2026-10-13 00:05-00:12 UTC): nearly every call is
  `emitted=0 skipped_stale=N`, N up to 224.

There is also a correctness bug: `Transaction.all` is roughly oldest first, so
the entry that gets evaluated is usually the oldest renewal, not the latest.
Its old `expiresDate` means the RENEWED branch can never fire from the
reconcile when there is more than one transaction for the OTID.

## Revision 1 (after adversarial review, 2026-10-12)

The review approved with changes. Verified in code:
- Crossgrades keep one originalTransactionId across products, and the old
  product's `EntitlementState` keeps it (`iap_views.py` `_expire_superseded_subscriptions`).
  The reconcile prefetch picks the lowest-id row per OTID, which is the old
  product. Once the latest transaction is sent, RENEWED (valid from TERMINAL)
  would bring the superseded product back. So the SDK change is only safe with
  a backend fix shipped first.
- The reconcile compares `appAccountToken` to the raw user id
  (`subscription_state_reconcile.py:266-268`), so every user with a non-UUID id
  is skipped as `app_account_token_mismatch`. The per-transaction path uses
  `appaccount_token_matches_user_id` correctly.
- Trial detection gets better too: today `detect_apple_trial` reads the oldest
  (trial) transaction.

The fingerprint skip is dropped: the backend staleness gate already makes an
unchanged resend a no-op, and the skip could suppress needed sends.

## Changes

### Backend (ships first, staging then prod)

B1. In `process_reconcile_entry`, match the state by `(otid, productId)` and
fall back to OTID only when no product match exists. Test with a crossgraded
OTID (two rows, one superseded).

B2. Check the token with `appaccount_token_matches_user_id(..., bundle_id=apple_reg(app).bundle_id)`
instead of the literal compare. Test a derived token is accepted, a foreign one
rejected.

B3. Guard for old SDKs: before JWS verification, decode the payloads unverified,
keep one entry per OTID (greatest `purchaseDate`), and verify only those.

### SDK (1.6.2)

S1. Subscriptions: one entry per `Product.SubscriptionInfo.status(for:)` status,
using `status.transaction.jwsRepresentation` and
`status.renewalInfo.jwsRepresentation`. If `status(for:)` throws for a group,
fall back to the latest `Transaction.all` transaction per OTID (greatest
`purchaseDate`, tie by greater id) with no renewal info.

S2. Non-subscriptions (`subscriptionGroupID == nil`): from `Transaction.all`,
deduped by id, unchanged otherwise (REVOKED handles refunded non-consumables).

S3. After selection, drop an entry whose `appAccountToken` is set and differs
from `AppAccountToken.derive(userId:bundleId:)`. If the bundle id is nil or
empty, skip the filter (derive has a precondition).

S4. Fix the doc comment claiming a 6-month `Transaction.all` cap.

Selection and filtering live in pure functions over small value types so they
are unit-testable without StoreKit.

### Not changing

- Wire format, endpoint, chunking, when reconcile runs.

## Other SDKs

Android, Flutter and React Native have no equivalent bulk reconcile (Flutter and
RN wrap this SDK, so they pick the change up on the next ZeroSettleKit bump).
To verify during review: grep the Android SDK for a `Transaction.all`-style
bulk sync.

## Tests (scoped, no full suite)

`SubscriptionStateReconcileTests`:
- foreign-token filter (after selection): nil kept, derived token kept,
  UUID user id kept, other token dropped, nil bundle id skips the filter;
- fallback selection: latest per OTID by purchaseDate, tie by id;
- non-subscriptions deduped by id.

Backend: `api.tests` reconcile module only, with a throwaway DB name.

Run only this suite:
`xcodebuild test -scheme ZeroSettleKit -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ZeroSettleKitTests/SubscriptionStateReconcileTests`.
A full test run needs Ryan's OK.

## Release

Patch release (1.6.2). Ryan tags and publishes, then bumps Flutter and RN.

## Rules for implementers

- All coding by `sonnet`, in this worktree. Never Opus.
- No long-running work (full suites, UI sweeps) without Ryan's explicit OK.
- Add only the exact files you changed; never `git add -A`. No stash.
