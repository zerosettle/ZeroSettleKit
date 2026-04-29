//
//  StoreKitManager.swift
//  ZeroSettleKit
//
//  Listens to StoreKit 2 transaction updates and forwards JWS to ZeroSettle backend.
//

import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Typealias to disambiguate StoreKit.Transaction from our Transaction model.
internal typealias SKTransaction = StoreKit.Transaction

// MARK: - StoreKit Purchase Error

/// Errors that can occur during StoreKit purchases.
///
/// - Note: Prefer catching ``ZeroSettleError`` instead, which unifies all SDK errors.
///   `StoreKitPurchaseError` cases map to `ZeroSettleError` as follows:
///   - `.productNotFound` → ``ZSError/productNotFound(_:)``
///   - `.verificationFailed` → ``ZSError/storeKitVerificationFailed(underlyingError:)``
///   - `.userCancelled` → ``ZSError/cancelled``
///   - `.pending` → ``ZSError/purchasePending``
internal enum StoreKitPurchaseError: Error, LocalizedError {
    case productNotFound(String)
    case verificationFailed(Error)
    case userCancelled
    case pending
    case unknown

    public var errorDescription: String? {
        switch self {
        case .productNotFound(let id):
            return "Product not found: \(id)"
        case .verificationFailed(let error):
            return "Verification failed: \(error.localizedDescription)"
        case .userCancelled:
            return "Purchase was cancelled"
        case .pending:
            return "Purchase is pending approval"
        case .unknown:
            return "An unknown error occurred"
        }
    }
}

// MARK: - StoreKit Update Delegate

/// Internal delegate for receiving StoreKit sync events.
protocol StoreKitUpdateDelegate: AnyObject {
    @MainActor func storeKitDidSyncTransaction(productId: String, transactionId: UInt64, originalTransactionId: String?)
    @MainActor func storeKitSyncFailed(error: Error)
}

// MARK: - StoreKit Manager

/// Listens to StoreKit 2 `Transaction.updates` and forwards JWS to the ZeroSettle backend.
/// Also provides access to current entitlements derived from StoreKit transactions.
@MainActor
internal final class StoreKitManager {
    private let backend: Backend
    private let syncQueue = StoreKitSyncQueue()
    private var updateListenerTask: Task<Void, Never>?
    private var userId: String?

    /// Optional local subscription monitor. When provided, its current
    /// `willAutoRenew` / `renewalState` snapshot is attached to the StoreKit
    /// sync payload so the backend ledger reflects the user's latest
    /// App-Store-side state (Patch 2B pairing).
    private weak var subscriptionMonitor: StoreKitSubscriptionMonitor?

    weak var delegate: StoreKitUpdateDelegate?

    init(backend: Backend, subscriptionMonitor: StoreKitSubscriptionMonitor? = nil) {
        self.backend = backend
        self.subscriptionMonitor = subscriptionMonitor
    }

    // MARK: - Listening

    /// Start listening for StoreKit transaction updates.
    /// - Parameter userId: The developer's user ID to associate with synced transactions
    func startListening(userId: String? = nil) {
        self.userId = userId
        stopListening()

        updateListenerTask = Task(priority: .utility) { [weak self] in
            await self?.listenForUpdates()
        }

        // Retry any pending syncs from previous sessions. The retry path does
        // not have per-transaction product context, so willAutoRenew/renewalState
        // are omitted here — next live transaction update will refresh them.
        let backend = self.backend
        let syncQueue = self.syncQueue
        Task(priority: .utility) { [weak self] in
            guard self != nil else { return }
            await syncQueue.retryAll { @Sendable jws, userId in
                try await backend.syncStoreKitTransaction(
                    jwsRepresentation: jws,
                    userId: userId
                )
            }
        }

    }

    // MARK: - Renewal State Enrichment

    /// Snapshot of `willAutoRenew` + `renewalState` for the given product,
    /// sourced from the local ``StoreKitSubscriptionMonitor``. Returned as a
    /// tuple-less struct so call sites stay readable.
    private struct RenewalSnapshot {
        let willAutoRenew: Bool?
        let renewalState: String?
    }

    private func renewalSnapshot(for productId: String) -> RenewalSnapshot {
        guard let info = subscriptionMonitor?.subscriptionInfoByProductId[productId] else {
            return RenewalSnapshot(willAutoRenew: nil, renewalState: nil)
        }
        return RenewalSnapshot(
            willAutoRenew: info.willAutoRenew,
            renewalState: info.renewalState.rawValue
        )
    }

    /// Stop listening for StoreKit transaction updates.
    func stopListening() {
        updateListenerTask?.cancel()
        updateListenerTask = nil
    }

    /// Drop every pending sync from the persistent retry queue. Used by
    /// ``ZeroSettle/logout()`` so a previous user's queued syncs never
    /// run under a new user. The transactions remain unfinished in
    /// StoreKit and will be redelivered next launch.
    func clearSyncQueue() async {
        await syncQueue.clearAll()
    }

    /// Update the user ID for subsequent sync operations.
    /// Pass `nil` to clear (e.g., on logout).
    func setUserId(_ userId: String?) {
        self.userId = userId
    }

    /// The currently set user ID (nil if not set).
    var currentUserId: String? {
        userId
    }

    // MARK: - Product Fetching

    /// Fetch StoreKit products for reconciliation with ZeroSettle catalog.
    /// - Parameter productIds: Array of product identifiers to fetch
    /// - Returns: Dictionary mapping product IDs to their StoreKit products
    func fetchProducts(for productIds: [String]) async -> [String: StoreKit.Product] {
        guard !productIds.isEmpty else { return [:] }

        do {
            let products = try await StoreKit.Product.products(for: Set(productIds))
            var productMap: [String: StoreKit.Product] = [:]
            for product in products {
                productMap[product.id] = product
            }

            let missingIds = Set(productIds).subtracting(productMap.keys)
            if !missingIds.isEmpty {
                ZSLogger.info("StoreKit missing product IDs: \(Array(missingIds))", category: .entitlements)
            }

            return productMap
        } catch {
            ZSLogger.error("Failed to fetch StoreKit products: \(error)", category: .entitlements)
            return [:]
        }
    }

    // MARK: - Purchasing

    /// Purchase a product via StoreKit 2.
    /// - Parameter product: The StoreKit product to purchase
    /// - Returns: The verified transaction
    func purchase(_ product: StoreKit.Product) async throws -> SKTransaction {
        // Set appAccountToken so the backend can attribute cross-account
        // ownership transfers without waiting for an SDK sync. Apple requires
        // a UUID; for non-UUID `userId` formats (Firebase, Privy, Auth0, ...)
        // we derive a stable UUIDv5 with a tenant-scoped namespace. The
        // backend's `apple_verified_current_owner` check accepts both the
        // literal-UUID form and the derived form. See AppAccountToken.swift
        // (and the matching api/services/appaccount_token.py on the server).
        var purchaseOptions: Set<StoreKit.Product.PurchaseOption> = []
        if let uid = userId, !uid.isEmpty, let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            let token = AppAccountToken.derive(userId: uid, bundleId: bundleId)
            purchaseOptions.insert(.appAccountToken(token))
        }

        let result: StoreKit.Product.PurchaseResult
        #if canImport(UIKit)
        if let scene = activeScene() {
            result = try await product.purchase(confirmIn: scene, options: purchaseOptions)
        } else {
            result = try await product.purchase(options: purchaseOptions)
        }
        #else
        result = try await product.purchase(options: purchaseOptions)
        #endif

        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                let jws = verification.jwsRepresentation
                await handleVerifiedTransaction(transaction, jwsRepresentation: jws)
                return transaction
            case .unverified(_, let error):
                throw StoreKitPurchaseError.verificationFailed(error)
            }
        case .userCancelled:
            throw StoreKitPurchaseError.userCancelled
        case .pending:
            throw StoreKitPurchaseError.pending
        @unknown default:
            throw StoreKitPurchaseError.unknown
        }
    }

    // MARK: - Unfinished Transaction Cleanup

    /// Finishes any unfinished StoreKit transactions for expired subscriptions.
    ///
    /// In sandbox, subscriptions auto-renew rapidly and each renewal creates a
    /// transaction. If the app didn't `finish()` them (e.g. backend sync failed),
    /// they accumulate and block new purchases — StoreKit returns the stale
    /// transaction instead of presenting the purchase dialog.
    func finishExpiredTransactions() async {
        let now = Date()
        var finished = 0
        for await result in SKTransaction.unfinished {
            guard case .verified(let transaction) = result else { continue }
            if let expiration = transaction.expirationDate, expiration < now {
                await transaction.finish()
                finished += 1
                ZSLogger.info("Finished expired unfinished transaction: \(transaction.productID) (id: \(transaction.id), expired: \(expiration))", category: .entitlements)
            }
        }
        if finished > 0 {
            ZSLogger.info("Cleaned up \(finished) expired unfinished transaction(s)", category: .entitlements)
        }
    }

    // MARK: - Transaction Sync

    /// Syncs all current StoreKit entitlements to the backend.
    /// Returns the set of `original_transaction_id`s confirmed as owned by the current user.
    func syncCurrentTransactions(userId: String) async -> Set<String> {
        var ownedOriginalTransactionIds: Set<String> = []
        var seenTransactionIds: [String] = []

        for await result in SKTransaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            let jws = result.jwsRepresentation
            let snapshot = renewalSnapshot(for: transaction.productID)
            // Family Sharing transactions belong to a different Apple ID — do not
            // treat them as owned by this device's account. The backend will refuse
            // the entitlement (owned=false), but we also skip adding to the owned
            // set so filterOwnedEntitlements never surfaces a family-shared row
            // as if it were directly owned.
            let isDirectlyOwned = transaction.ownershipType == .purchased
            seenTransactionIds.append("\(transaction.id)/orig=\(transaction.originalID)/product=\(transaction.productID)/ownership=\(transaction.ownershipType)")
            do {
                let response = try await backend.syncStoreKitTransaction(
                    jwsRepresentation: jws,
                    userId: userId,
                    willAutoRenew: snapshot.willAutoRenew,
                    renewalState: snapshot.renewalState
                )
                // Backend is authoritative for ownership. Only mark owned if the
                // backend confirms it. Family-shared transactions will return
                // owned=false and must not be surfaced as directly owned.
                if response.owned == true && transaction.originalID != 0 {
                    ownedOriginalTransactionIds.insert(String(transaction.originalID))
                }
                if response.owned == true, let origId = response.originalTransactionId {
                    ownedOriginalTransactionIds.insert(origId)
                }
                if response.owned == false {
                    ZSLogger.info("[syncCurrentTransactions] Server returned owned=false for txn id=\(transaction.id) product=\(transaction.productID) ownership=\(transaction.ownershipType) — not tracked", category: .entitlements)
                }
                ZSLogger.info("[syncCurrentTransactions] txn id=\(transaction.id) origID=\(transaction.originalID) product=\(transaction.productID) ownership=\(transaction.ownershipType) → backend owned=\(response.owned ?? true) origTxnId=\(response.originalTransactionId ?? "nil")", category: .entitlements)
            } catch {
                // Do NOT optimistically mark this transaction as owned on
                // error. Pre-1.2.5 we did, on the assumption that a directly-
                // owned transaction "must" belong to this user. But during a
                // transient backend hiccup, this could mask a real cross-
                // account collision: another ZS account had previously
                // claimed this OTID, and the backend would normally have
                // returned owned=false. Optimistic insertion gave the user
                // an entitlement they shouldn't have until the next refresh.
                //
                // Now: log and skip. The user will retry via the next
                // restoreEntitlements() / identify() call. Worst case the
                // user briefly doesn't see an entitlement they own — which
                // is recoverable. Better than briefly seeing one they don't.
                ZSLogger.error("[syncCurrentTransactions] FAILED txn id=\(transaction.id) origID=\(transaction.originalID) product=\(transaction.productID) ownership=\(transaction.ownershipType): \(error). Skipping — will retry on next sync.", category: .entitlements)
            }
        }

        ZSLogger.info("[syncCurrentTransactions] saw \(seenTransactionIds.count) txn(s): \(seenTransactionIds). Final owned set: \(ownedOriginalTransactionIds)", category: .entitlements)
        return ownedOriginalTransactionIds
    }

    // MARK: - Current Entitlements

    /// Get the current entitlements from StoreKit's verified transactions.
    ///
    /// For subscriptions, also queries `Product.SubscriptionInfo.Status` to get
    /// the real-time `willAutoRenew` flag from `RenewalInfo`. This is more
    /// up-to-date than `Transaction.currentEntitlements` alone, which Apple
    /// caches aggressively in sandbox (often several minutes stale).
    func getCurrentEntitlements() async -> [Entitlement] {
        var entitlements: [Entitlement] = []

        for await result in SKTransaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }

            // For subscriptions, fetch real-time renewal status and original
            // transaction ID in a single StoreKit call to avoid redundant fetches.
            let subscriptionInfo: SubscriptionInfo? = transaction.expirationDate != nil
                ? await fetchSubscriptionInfo(for: transaction.productID)
                : nil

            // Transaction.originalID can return 0 in Xcode StoreKit testing.
            // Fall back to RenewalInfo.originalTransactionID which is more reliable.
            var originalTxnId = transaction.originalID
            if originalTxnId == 0 {
                if let renewalOrigId = subscriptionInfo?.originalTransactionID {
                    originalTxnId = renewalOrigId
                } else {
                    originalTxnId = transaction.id
                }
            }

            let renewalStatus: RenewalStatus? = subscriptionInfo.map {
                RenewalStatus(willAutoRenew: $0.willAutoRenew)
            }

            ZSLogger.info("[getCurrentEntitlements] txn id=\(transaction.id) origID=\(originalTxnId) product=\(transaction.productID) expires=\(transaction.expirationDate?.description ?? "nil")", category: .entitlements)

            let entitlement = entitlementFromTransaction(
                transaction,
                originalTransactionId: originalTxnId,
                renewalStatus: renewalStatus
            )
            entitlements.append(entitlement)
        }

        ZSLogger.info("[getCurrentEntitlements] returning \(entitlements.count) entitlement(s): \(entitlements.map { "\($0.productId)/orig=\($0.storekitOriginalTransactionId ?? "nil")" })", category: .entitlements)
        return entitlements
    }

    /// Finds the JWS representation of a StoreKit transaction for the given product ID.
    /// Searches `Transaction.currentEntitlements` on the current Apple ID.
    /// Returns nil if no transaction exists for this product.
    func findTransactionJWS(for productId: String) async -> String? {
        for await result in SKTransaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == productId {
                return result.jwsRepresentation
            }
        }
        return nil
    }

    /// Real-time renewal status from `Product.SubscriptionInfo.Status`.
    struct RenewalStatus {
        let willAutoRenew: Bool
    }

    /// Combined subscription info from a single `Product.SubscriptionInfo.Status` query.
    private struct SubscriptionInfo {
        let willAutoRenew: Bool
        let originalTransactionID: UInt64
    }

    /// Fetches real-time subscription info (renewal status and original transaction ID)
    /// in a single StoreKit call, avoiding redundant `Product.products(for:)` queries.
    private func fetchSubscriptionInfo(for productId: String) async -> SubscriptionInfo? {
        guard let product = try? await Product.products(for: [productId]).first,
              let subscription = product.subscription,
              let statuses = try? await subscription.status,
              let status = statuses.first(where: { $0.state == .subscribed }) ?? statuses.first,
              case .verified(let renewalInfo) = status.renewalInfo else {
            return nil
        }
        ZSLogger.debug("SubscriptionInfo for product=\(productId): willAutoRenew=\(renewalInfo.willAutoRenew), originalTransactionID=\(renewalInfo.originalTransactionID)", category: .entitlements)
        return SubscriptionInfo(
            willAutoRenew: renewalInfo.willAutoRenew,
            originalTransactionID: renewalInfo.originalTransactionID
        )
    }

    // MARK: - Private

    private func listenForUpdates() async {
        for await result in SKTransaction.updates {
            guard !Task.isCancelled else { break }

            switch result {
            case .verified(let transaction):
                let jws = result.jwsRepresentation
                await handleVerifiedTransaction(transaction, jwsRepresentation: jws)
            case .unverified(_, let error):
                ZSLogger.error("Unverified transaction: \(error.localizedDescription)", category: .entitlements)
            }
        }
    }

    private func handleVerifiedTransaction(_ transaction: SKTransaction, jwsRepresentation: String) async {
        ZSLogger.info("StoreKit transaction received: \(transaction.productID) (id: \(transaction.id))", category: .entitlements)

        // If no userId is set, leave the transaction unfinished and return.
        // StoreKit will redeliver via Transaction.updates on the next launch,
        // giving the developer another chance to identify the user before the
        // sync fires. We do NOT enqueue here — without a userId we can't
        // attribute the retry to anyone.
        guard let userId = userId else {
            ZSLogger.error(
                "ZeroSettleKit: StoreKit transaction \(transaction.id) for product '\(transaction.productID)' will NOT sync to the backend because no user is identified. " +
                "Call ZeroSettle.shared.identify(userId:) (or bootstrap(userId:) on 1.x) at app launch BEFORE any purchase can complete. " +
                "The transaction is left unfinished so StoreKit will redeliver it once you identify the user.",
                category: .entitlements
            )
#if DEBUG
            assertionFailure(
                "ZeroSettleKit: StoreKit transaction received but no userId is set. " +
                "Call ZeroSettle.shared.identify(userId:) before StoreKit transactions can fire. " +
                "This assertion only fires in DEBUG; in RELEASE the transaction is left unfinished and will be retried."
            )
#endif
            return
        }

        // appAccountToken sanity check: warn if the JWS-signed token doesn't
        // match the canonical UUIDv5 derivation for this user. The backend's
        // `apple_verified_current_owner` check requires either literal-match
        // (UUID-native dev IDs) or derivation-match. A mismatch means cross-
        // account ownership transfer (family sharing, cancel+rebuy, reinstall+
        // resignin) will refuse on this transaction. Common cause: dev rolled
        // their own UUID derivation that produces random or non-deterministic
        // UUIDs (see DiveGenius incident, 2026-04-28).
        //
        // We don't fail the sync — same-user attribution still works, and
        // failing would prevent legitimate purchases from being recorded.
        // The warning is loud-and-actionable so the dev fixes it.
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty,
           let jwsToken = transaction.appAccountToken {
            let expected = AppAccountToken.derive(userId: userId, bundleId: bundleId)
            if jwsToken != expected {
                ZSLogger.error(
                    "ZeroSettleKit: appAccountToken mismatch on transaction \(transaction.id). " +
                    "JWS contains \(jwsToken.uuidString) but expected \(expected.uuidString) for userId='\(userId)'. " +
                    "Cross-account ownership transfer will not work for this transaction. " +
                    "Fix: either call ZeroSettle.shared.purchaseViaStoreKit(productId:) (recommended — the SDK handles appAccountToken for you), " +
                    "or if you must call StoreKit's Product.purchase() directly, get the correct UUID from " +
                    "ZeroSettle.shared.recommendedAppAccountToken() and pass it as .appAccountToken(...) in the purchase options.",
                    category: .entitlements
                )
            }
        }

        // Refresh monitor state before syncing so the payload reflects the
        // latest willAutoRenew/renewalState for this product. This is what
        // lets the backend detect an Apple cancellation on the next sync
        // even if ASSN never arrives.
        if let monitor = subscriptionMonitor {
            await monitor.refreshAll()
        }
        let snapshot = renewalSnapshot(for: transaction.productID)

        // Forward JWS to ZeroSettle backend for server-side verification
        do {
            let response = try await backend.syncStoreKitTransaction(
                jwsRepresentation: jwsRepresentation,
                userId: userId,
                willAutoRenew: snapshot.willAutoRenew,
                renewalState: snapshot.renewalState
            )
            if response.owned == false {
                ZSLogger.error("Server returned owned=false for a new purchase — unexpected. product=\(transaction.productID)", category: .entitlements)
            }

            // Sync succeeded — dequeue any previous retry entry, then finish
            await syncQueue.dequeue(transaction.id)
            await transaction.finish()

            ZSLogger.info("StoreKit transaction synced: \(transaction.productID)", category: .entitlements)
            delegate?.storeKitDidSyncTransaction(
                productId: transaction.productID,
                transactionId: transaction.id,
                originalTransactionId: response.originalTransactionId
            )

            // Nudge offer managers to re-evaluate with fresh server state so
            // switch & save can pop immediately after the new sub without
            // requiring an app relaunch.
            await ZeroSettle.shared.refreshOfferEligibility()
        } catch {
            // Sync failed — enqueue for retry, do NOT finish (StoreKit will redeliver)
            ZSLogger.error("Failed to sync StoreKit transaction: \(error)", category: .entitlements)

            await syncQueue.enqueue(StoreKitSyncQueue.PendingSync(
                jwsRepresentation: jwsRepresentation,
                userId: userId,
                transactionId: transaction.id,
                attemptCount: 0,
                lastAttemptAt: Date()
            ))

            delegate?.storeKitSyncFailed(error: error)
        }

        // Refresh published entitlements from both local StoreKit and backend.
        // Called unconditionally (success or sync failure) so downstream
        // consumers — ZSOfferManager, Switch & Save, debug env view, any
        // @ObservedObject/@StateObject SwiftUI view — see the latest ownership
        // state. Replaces a prior lossy merge that dropped backend-returned
        // storekit entitlements, causing premium UI to flash on then off.
        await ZeroSettle.shared.refreshEntitlementsAndPublish()
    }

    private func entitlementFromTransaction(
        _ transaction: SKTransaction,
        originalTransactionId: UInt64? = nil,
        renewalStatus: RenewalStatus? = nil
    ) -> Entitlement {
        let isActive: Bool
        let expiresAt: Date?

        if let expiration = transaction.expirationDate {
            isActive = expiration > Date()
            expiresAt = expiration
        } else if transaction.revocationDate != nil {
            isActive = false
            expiresAt = nil
        } else {
            // Non-expiring (non-consumable or lifetime)
            isActive = true
            expiresAt = nil
        }

        let origId = originalTransactionId ?? (transaction.originalID != 0 ? transaction.originalID : transaction.id)

        // Use real-time renewal status when available; default to true for
        // non-subscription products or when status couldn't be fetched.
        let willRenew = renewalStatus?.willAutoRenew ?? true
        let cancelledAt: Date? = (renewalStatus != nil && !willRenew) ? Date() : nil
        let status: Entitlement.Status = {
            if !isActive { return .expired }
            if cancelledAt != nil { return .cancelled }
            return .active
        }()

        return Entitlement(
            id: "storekit_\(transaction.id)",
            productId: transaction.productID,
            source: .storeKit,
            isActive: isActive,
            status: status,
            expiresAt: expiresAt,
            willRenew: willRenew,
            cancelledAt: cancelledAt,
            purchasedAt: transaction.purchaseDate,
            storekitOriginalTransactionId: String(origId),
            originalPurchaseDate: transaction.originalPurchaseDate
        )
    }

    #if canImport(UIKit)
    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    #endif
}
