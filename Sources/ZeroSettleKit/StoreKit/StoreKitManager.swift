//
//  StoreKitManager.swift
//  ZeroSettleKit
//
//  Listens to StoreKit 2 transaction updates and forwards JWS to ZeroSettle backend.
//

import Foundation
import StoreKit

#if canImport(ZeroSettleCore)
@_implementationOnly import ZeroSettleCore
#endif

/// Typealias to disambiguate StoreKit.Transaction from our Transaction model.
public typealias SKTransaction = StoreKit.Transaction

// MARK: - StoreKit Purchase Error

/// Errors that can occur during StoreKit purchases.
///
/// - Note: Prefer catching ``ZSError`` instead, which unifies all SDK errors.
///   `StoreKitPurchaseError` cases map to `ZSError` as follows:
///   - `.productNotFound` → ``ZSError/productNotFound(_:)``
///   - `.verificationFailed` → ``ZSError/storeKitVerificationFailed(underlyingError:)``
///   - `.userCancelled` → ``ZSError/cancelled``
///   - `.pending` → ``ZSError/purchasePending``
public enum StoreKitPurchaseError: Error, LocalizedError {
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

        Logger.info("StoreKit transaction listener started", category: .iap)
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

        Logger.info("Requesting \(productIds.count) products from StoreKit: \(productIds)", category: .iap)

        do {
            let products = try await StoreKit.Product.products(for: Set(productIds))
            var productMap: [String: StoreKit.Product] = [:]
            for product in products {
                productMap[product.id] = product
                Logger.info("StoreKit found: \(product.id) - \(product.displayName) - \(product.displayPrice)", category: .iap)
            }

            let missingIds = Set(productIds).subtracting(productMap.keys)
            if !missingIds.isEmpty {
                Logger.info("StoreKit did NOT find these product IDs: \(Array(missingIds))", category: .iap)
            }

            Logger.info("Fetched \(products.count)/\(productIds.count) StoreKit products", category: .iap)
            return productMap
        } catch {
            Logger.error("Failed to fetch StoreKit products: \(error)", category: .iap)
            return [:]
        }
    }

    // MARK: - Purchasing

    /// Purchase a product via StoreKit 2.
    /// - Parameter product: The StoreKit product to purchase
    /// - Returns: The verified transaction
    func purchase(_ product: StoreKit.Product) async throws -> SKTransaction {
        let result = try await product.purchase()

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

    // MARK: - Current Entitlements

    /// Get the current entitlements from StoreKit's verified transactions.
    func getCurrentEntitlements() async -> [Entitlement] {
        var entitlements: [Entitlement] = []

        for await result in SKTransaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            let entitlement = entitlementFromTransaction(transaction)
            entitlements.append(entitlement)
        }

        return entitlements
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
                Logger.error("Unverified transaction: \(error.localizedDescription)", category: .iap)
            }
        }
    }

    private func handleVerifiedTransaction(_ transaction: SKTransaction, jwsRepresentation: String) async {
        Logger.info("StoreKit transaction received: \(transaction.productID) (id: \(transaction.id))", category: .iap)

        // Finish the transaction
        await transaction.finish()

        // Forward JWS to ZeroSettle backend for server-side verification
        guard let userId = userId else {
            Logger.debug("No userId set, skipping StoreKit sync", category: .iap)
            return
        }

        do {
            try await backend.syncStoreKitTransaction(
                jwsRepresentation: jwsRepresentation,
                userId: userId
            )

            Logger.info("StoreKit transaction synced: \(transaction.productID)", category: .iap)
            await MainActor.run {
                delegate?.storeKitDidSyncTransaction(
                    productId: transaction.productID,
                    transactionId: transaction.id
                )
            }
        } catch {
            Logger.error("Failed to sync StoreKit transaction: \(error)", category: .iap)
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

    private func entitlementFromTransaction(_ transaction: SKTransaction) -> Entitlement {
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

        return Entitlement(
            id: "storekit_\(transaction.id)",
            productId: transaction.productID,
            source: .storeKit,
            isActive: isActive,
            expiresAt: expiresAt,
            purchasedAt: transaction.purchaseDate
        )
    }
}
