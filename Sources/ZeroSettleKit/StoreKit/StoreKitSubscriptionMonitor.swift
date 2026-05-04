//
//  StoreKitSubscriptionMonitor.swift
//  ZeroSettleKit
//
//  Observes StoreKit 2 subscription state changes (cancel, revoke, expire) and
//  publishes them locally. Works without ASSN webhooks.
//
//  Used by UI (Switch & Save, offer state machine) to transition to terminal
//  states the moment the user takes action in App Store Settings — no server
//  round-trip required.
//
//  Also exposes state so `StoreKitManager` can attach `willAutoRenew` +
//  `renewalState` to the StoreKit sync payload (Patch 2B pairing) so the
//  backend ledger stays accurate for dashboard purposes.
//

import Foundation
import StoreKit

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Observes `StoreKit.Transaction.updates` and `Product.SubscriptionInfo.Status`
/// to detect the moment a user cancels/revokes/expires a subscription.
///
/// Emits on `stateChanges` whenever a product's `willAutoRenew` flag flips or
/// its `RenewalState` transitions. Consumers (e.g. ``ZSOfferManager``) await
/// values to drive UI transitions that previously required ASSN delivery.
@MainActor
internal final class StoreKitSubscriptionMonitor {

    // MARK: - Types

    /// Snapshot of a subscription's renewal state at a point in time.
    internal struct SubscriptionInfo: Sendable, Equatable {
        let productId: String
        let originalTransactionId: String
        let willAutoRenew: Bool
        let renewalState: RenewalState
        let observedAt: Date
    }

    /// Mirrors `Product.SubscriptionInfo.RenewalState` in a source-stable enum
    /// that is serialisation-friendly (the raw value is sent to the backend on
    /// sync so `Patch 2B` can reason about it).
    internal enum RenewalState: String, Sendable {
        case subscribed
        case expired
        case inBillingRetryPeriod = "in_billing_retry_period"
        case inGracePeriod = "in_grace_period"
        case revoked
        case unknown

        init(from stateValue: Product.SubscriptionInfo.RenewalState) {
            switch stateValue {
            case .subscribed: self = .subscribed
            case .expired: self = .expired
            case .inBillingRetryPeriod: self = .inBillingRetryPeriod
            case .inGracePeriod: self = .inGracePeriod
            case .revoked: self = .revoked
            default: self = .unknown
            }
        }
    }

    // MARK: - Public State

    /// Most recently observed state per product_id. Consumers (including the
    /// sync pipeline in ``StoreKitManager``) can read this synchronously to
    /// enrich network payloads.
    private(set) var subscriptionInfoByProductId: [String: SubscriptionInfo] = [:]

    /// Fires whenever any observed subscription's state changes (including
    /// `willAutoRenew` toggle). Consumers await values to update UI immediately.
    let stateChanges: AsyncStream<SubscriptionInfo>

    // MARK: - Private State

    private var continuation: AsyncStream<SubscriptionInfo>.Continuation?
    private var updateListenerTask: Task<Void, Never>?

    #if canImport(UIKit)
    /// Observer token for `UIApplication.didBecomeActiveNotification`. Retained
    /// so we can explicitly remove it on `stop()` / `deinit`.
    private var didBecomeActiveObserver: (any NSObjectProtocol)?
    #endif

    // MARK: - Init

    init() {
        var localContinuation: AsyncStream<SubscriptionInfo>.Continuation!
        self.stateChanges = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { cont in
            localContinuation = cont
        }
        self.continuation = localContinuation
    }

    deinit {
        continuation?.finish()
        // Note: we intentionally don't remove `didBecomeActiveObserver` here.
        // The block-based observer captures `self` weakly, so once the monitor
        // is released the block becomes a no-op and NotificationCenter cleans
        // up the dangling registration on the next post. Explicit removal
        // happens in `stop()` when the SDK is torn down deliberately.
    }

    // MARK: - Lifecycle

    /// Start observing. Safe to call multiple times — subsequent calls are no-ops
    /// while a listener is already running.
    func start() {
        guard updateListenerTask == nil else { return }

        updateListenerTask = Task { [weak self] in
            guard let self else { return }
            // Seed current state so sync payloads have data on launch, even
            // before a Transaction.updates event fires.
            await self.refreshAll()
            await self.observeUpdates()
        }

        #if canImport(UIKit)
        // StoreKit's `Transaction.updates` async stream does NOT fire on pure
        // `willAutoRenew` flips (the event Apple emits when a user cancels a
        // subscription via Settings). Without an extra trigger, a cancellation
        // made after app launch stays invisible until the next real transaction
        // event. Re-pull every time the app returns to foreground so any
        // off-app toggle (Settings → Subscriptions → Cancel) surfaces the
        // moment the user comes back.
        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { [weak self] in await self?.refreshAll() }
            }
        }
        #endif
    }

    /// Stop observing. Used during SDK teardown / tests.
    func stop() {
        updateListenerTask?.cancel()
        updateListenerTask = nil

        #if canImport(UIKit)
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
        #endif
    }

    /// Force a fresh read of every current entitlement's renewal state and emit
    /// any changes. Cheap — each call is one `Transaction.currentEntitlements`
    /// pull and a handful of `Product.products(for:)` lookups. Safe to call
    /// from UI code paths that evaluate offer / cancel state; the observed
    /// output still reaches consumers via `stateChanges`.
    func refreshIfStale() async {
        await refreshAll()
    }

    // MARK: - Queries

    /// Whether a specific product currently has auto-renew on. Returns `nil`
    /// if we have not yet observed that product.
    func willAutoRenew(for productId: String) -> Bool? {
        subscriptionInfoByProductId[productId]?.willAutoRenew
    }

    // MARK: - Refresh

    /// Re-fetches state for every current entitlement. Invoked on `start()` so
    /// the monitor has data before any `Transaction.updates` fires, and on
    /// `didBecomeActive` so subscription cancellations that happened in the
    /// App Store Settings app surface immediately on foreground.
    func refreshAll() async {
        var refreshedProductIds: [String] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            await self.updateFor(transaction: transaction)
            refreshedProductIds.append(transaction.productID)
        }

        if refreshedProductIds.isEmpty {
            ZSLogger.debug("[StoreKitSubscriptionMonitor] refreshAll: no current entitlements", category: .entitlements)
        } else {
            let summary = refreshedProductIds.map { id -> String in
                if let info = self.subscriptionInfoByProductId[id] {
                    return "\(id) willAutoRenew=\(info.willAutoRenew) state=\(info.renewalState.rawValue)"
                }
                return "\(id) (non-subscription or unknown)"
            }.joined(separator: ", ")
            ZSLogger.debug("[StoreKitSubscriptionMonitor] refreshAll: \(summary)", category: .entitlements)
        }
    }

    // MARK: - Private

    /// Updates state for one transaction; emits to `stateChanges` if something
    /// relevant changed (first observation, willAutoRenew toggle, renewalState
    /// transition).
    private func updateFor(transaction: StoreKit.Transaction) async {
        // Non-subscriptions have no renewal state to observe.
        guard transaction.expirationDate != nil else { return }

        do {
            let products = try await Product.products(for: [transaction.productID])
            guard let product = products.first,
                  let subscription = product.subscription else {
                return
            }

            let statuses = try await subscription.status
            // Prefer the status whose state is `.subscribed` if present; the
            // first otherwise. Matches `StoreKitManager.fetchSubscriptionInfo`.
            guard let status = statuses.first(where: { $0.state == .subscribed }) ?? statuses.first,
                  case .verified(let renewalInfo) = status.renewalInfo else {
                return
            }

            let origId: String
            if renewalInfo.originalTransactionID != 0 {
                origId = String(renewalInfo.originalTransactionID)
            } else if transaction.originalID != 0 {
                origId = String(transaction.originalID)
            } else {
                origId = String(transaction.id)
            }

            let newInfo = SubscriptionInfo(
                productId: transaction.productID,
                originalTransactionId: origId,
                willAutoRenew: renewalInfo.willAutoRenew,
                renewalState: RenewalState(from: status.state),
                observedAt: Date()
            )

            let previous = subscriptionInfoByProductId[transaction.productID]
            subscriptionInfoByProductId[transaction.productID] = newInfo

            // Emit only when something interesting changed.
            let changed: Bool
            if let previous {
                changed = previous.willAutoRenew != newInfo.willAutoRenew
                    || previous.renewalState != newInfo.renewalState
            } else {
                changed = true
            }

            if changed {
                ZSLogger.info(
                    "[StoreKitSubscriptionMonitor] \(transaction.productID) willAutoRenew=\(newInfo.willAutoRenew) renewalState=\(newInfo.renewalState.rawValue)",
                    category: .entitlements
                )
                continuation?.yield(newInfo)
            }
        } catch {
            ZSLogger.error(
                "[StoreKitSubscriptionMonitor] Failed to refresh \(transaction.productID): \(error)",
                category: .entitlements
            )
        }
    }

    /// Listens to `Transaction.updates` until cancelled. Each update re-queries
    /// the product's `SubscriptionInfo.Status` to pick up the latest
    /// `willAutoRenew` / `renewalState` values.
    private func observeUpdates() async {
        for await result in StoreKit.Transaction.updates {
            guard !Task.isCancelled else { break }
            guard case .verified(let transaction) = result else { continue }
            await self.updateFor(transaction: transaction)
        }
    }
}
