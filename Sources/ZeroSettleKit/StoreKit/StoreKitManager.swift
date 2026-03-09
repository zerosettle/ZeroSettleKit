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
    @MainActor func storeKitDidSyncTransaction(productId: String, transactionId: UInt64)
    @MainActor func storeKitSyncFailed(error: Error)
    @MainActor func storeKitEntitlementsDidChange(_ entitlements: [Entitlement])
}

// MARK: - StoreKit Manager

/// Listens to StoreKit 2 `Transaction.updates` and forwards JWS to the ZeroSettle backend.
/// Also provides access to current entitlements derived from StoreKit transactions.
internal final class StoreKitManager: @unchecked Sendable {
    private let backend: Backend
    private let syncQueue = StoreKitSyncQueue()
    private var updateListenerTask: Task<Void, Never>?
    private var userId: String?

    weak var delegate: StoreKitUpdateDelegate?

    init(backend: Backend) {
        self.backend = backend
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

        // Retry any pending syncs from previous sessions
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.syncQueue.retryAll { [weak self] jws, userId in
                try await self?.backend.syncStoreKitTransaction(
                    jwsRepresentation: jws,
                    userId: userId
                ) ?? { throw URLError(.cancelled) }()
            }
        }

        ZSLogger.info("StoreKit transaction listener started", category: .entitlements)
    }

    /// Stop listening for StoreKit transaction updates.
    func stopListening() {
        updateListenerTask?.cancel()
        updateListenerTask = nil
    }

    /// Update the user ID for subsequent sync operations.
    func setUserId(_ userId: String) {
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

        ZSLogger.info("Requesting \(productIds.count) products from StoreKit: \(productIds)", category: .entitlements)

        do {
            let products = try await StoreKit.Product.products(for: Set(productIds))
            var productMap: [String: StoreKit.Product] = [:]
            for product in products {
                productMap[product.id] = product
                ZSLogger.info("StoreKit found: \(product.id) - \(product.displayName) - \(product.displayPrice)", category: .entitlements)
            }

            let missingIds = Set(productIds).subtracting(productMap.keys)
            if !missingIds.isEmpty {
                ZSLogger.info("StoreKit did NOT find these product IDs: \(Array(missingIds))", category: .entitlements)
            }

            ZSLogger.info("Fetched \(products.count)/\(productIds.count) StoreKit products", category: .entitlements)
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
        let result: StoreKit.Product.PurchaseResult
        #if canImport(UIKit)
        if let scene = await activeScene() {
            result = try await product.purchase(confirmIn: scene)
        } else {
            result = try await product.purchase()
        }
        #else
        result = try await product.purchase()
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

    /// Sync all current StoreKit entitlements to the backend.
    /// Ensures the backend has Identity and Entitlement records for the user's
    /// active subscriptions before any migration eligibility checks.
    /// Idempotent — the backend deduplicates on storekit_transaction_id.
    func syncCurrentTransactions(userId: String) async {
        for await result in SKTransaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            let jws = result.jwsRepresentation
            do {
                try await backend.syncStoreKitTransaction(
                    jwsRepresentation: jws,
                    userId: userId
                )
                ZSLogger.info("Synced current transaction \(transaction.id) for \(transaction.productID)", category: .entitlements)
            } catch {
                ZSLogger.error("Failed to sync current transaction \(transaction.id): \(error)", category: .entitlements)
            }
        }
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

            // Transaction.originalID can return 0 in Xcode StoreKit testing.
            // Fall back to RenewalInfo.originalTransactionID which is more reliable.
            var originalTxnId = transaction.originalID
            if originalTxnId == 0 {
                if let renewalOrigId = await fetchOriginalTransactionId(for: transaction.productID) {
                    originalTxnId = renewalOrigId
                } else {
                    originalTxnId = transaction.id
                }
            }

            // For subscriptions, fetch real-time renewal status to detect cancellation
            // sooner than the cached transaction data would show it.
            let renewalStatus: RenewalStatus? = transaction.expirationDate != nil
                ? await fetchSubscriptionRenewalStatus(for: transaction.productID)
                : nil

            let entitlement = entitlementFromTransaction(
                transaction,
                originalTransactionId: originalTxnId,
                renewalStatus: renewalStatus
            )
            entitlements.append(entitlement)
        }

        return entitlements
    }

    /// Real-time renewal status from `Product.SubscriptionInfo.Status`.
    struct RenewalStatus {
        let willAutoRenew: Bool
    }

    /// Fetches the real-time renewal status for a subscription product.
    ///
    /// Uses `Product.SubscriptionInfo.Status` which reflects the current
    /// auto-renew preference immediately, unlike `Transaction.currentEntitlements`
    /// which can be cached for minutes in sandbox.
    private func fetchSubscriptionRenewalStatus(for productId: String) async -> RenewalStatus? {
        guard let product = try? await Product.products(for: [productId]).first,
              let subscription = product.subscription,
              let statuses = try? await subscription.status,
              let status = statuses.first(where: { $0.state == .subscribed }) ?? statuses.first,
              case .verified(let renewalInfo) = status.renewalInfo else {
            return nil
        }
        ZSLogger.debug("RenewalStatus for product=\(productId): willAutoRenew=\(renewalInfo.willAutoRenew)", category: .entitlements)
        return RenewalStatus(willAutoRenew: renewalInfo.willAutoRenew)
    }

    /// Fetches the original transaction ID from a subscription's RenewalInfo.
    private func fetchOriginalTransactionId(for productId: String) async -> UInt64? {
        guard let product = try? await Product.products(for: [productId]).first,
              let subscription = product.subscription,
              let statuses = try? await subscription.status,
              let status = statuses.first(where: { $0.state == .subscribed }) ?? statuses.first,
              case .verified(let renewalInfo) = status.renewalInfo else {
            return nil
        }
        let origId = renewalInfo.originalTransactionID
        ZSLogger.debug("RenewalInfo.originalTransactionID=\(origId) for product=\(productId)", category: .entitlements)
        return origId
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

        // If no userId is set, finish immediately and return (preserves pre-retry-queue behavior)
        guard let userId = userId else {
            ZSLogger.debug("No userId set, finishing transaction without sync", category: .entitlements)
            await transaction.finish()
            return
        }

        // Forward JWS to ZeroSettle backend for server-side verification
        do {
            try await backend.syncStoreKitTransaction(
                jwsRepresentation: jwsRepresentation,
                userId: userId
            )

            // Sync succeeded — dequeue any previous retry entry, then finish
            await syncQueue.dequeue(transaction.id)
            await transaction.finish()

            ZSLogger.info("StoreKit transaction synced: \(transaction.productID)", category: .entitlements)
            await MainActor.run {
                delegate?.storeKitDidSyncTransaction(
                    productId: transaction.productID,
                    transactionId: transaction.id
                )
            }
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

            await MainActor.run {
                delegate?.storeKitSyncFailed(error: error)
            }
        }

        // Refresh entitlements after a new transaction
        let entitlements = await getCurrentEntitlements()
        await MainActor.run {
            delegate?.storeKitEntitlementsDidChange(entitlements)
        }
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
    @MainActor
    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    #endif
}
