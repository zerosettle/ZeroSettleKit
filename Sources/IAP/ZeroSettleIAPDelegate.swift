//
//  ZeroSettleIAPDelegate.swift
//  ZeroSettleIAP
//
//  Delegate protocol for IAP event callbacks.
//

import Foundation

// MARK: - ZeroSettle IAP Delegate

/// Delegate protocol to receive callbacks for ZeroSettle IAP events.
/// All methods have default empty implementations — only implement what you need.
@MainActor
public protocol ZeroSettleIAPDelegate: AnyObject {

    // MARK: - Checkout Events

    /// Called when a web checkout begins (Safari is opening).
    /// - Parameter productId: The product being purchased
    func zeroSettleIAPCheckoutDidBegin(productId: String)

    /// Called when a web checkout completes successfully.
    /// - Parameter transaction: The completed transaction
    func zeroSettleIAPCheckoutDidComplete(transaction: Transaction)

    /// Called when the user cancels the web checkout (returns without purchasing).
    /// - Parameter productId: The product that was being purchased
    func zeroSettleIAPCheckoutDidCancel(productId: String)

    /// Called when a web checkout fails.
    /// - Parameters:
    ///   - productId: The product that was being purchased
    ///   - error: The underlying error
    func zeroSettleIAPCheckoutDidFail(productId: String, error: Error)

    // MARK: - Entitlement Events

    /// Called when the user's entitlements are updated (from either source).
    /// - Parameter entitlements: The updated list of all entitlements
    func zeroSettleIAPEntitlementsDidUpdate(_ entitlements: [Entitlement])

    // MARK: - StoreKit Sync Events

    /// Called when a native StoreKit transaction is successfully synced to ZeroSettle.
    /// Only fired when `syncStoreKitTransactions` is enabled in the configuration.
    /// - Parameters:
    ///   - productId: The product ID of the synced transaction
    ///   - transactionId: The StoreKit transaction ID
    func zeroSettleIAPDidSyncStoreKitTransaction(productId: String, transactionId: UInt64)

    /// Called when syncing a StoreKit transaction to ZeroSettle fails.
    /// - Parameter error: The underlying error
    func zeroSettleIAPStoreKitSyncFailed(error: Error)
}

// MARK: - Default Implementations

public extension ZeroSettleIAPDelegate {
    func zeroSettleIAPCheckoutDidBegin(productId: String) {}
    func zeroSettleIAPCheckoutDidComplete(transaction: Transaction) {}
    func zeroSettleIAPCheckoutDidCancel(productId: String) {}
    func zeroSettleIAPCheckoutDidFail(productId: String, error: Error) {}
    func zeroSettleIAPEntitlementsDidUpdate(_ entitlements: [Entitlement]) {}
    func zeroSettleIAPDidSyncStoreKitTransaction(productId: String, transactionId: UInt64) {}
    func zeroSettleIAPStoreKitSyncFailed(error: Error) {}
}
