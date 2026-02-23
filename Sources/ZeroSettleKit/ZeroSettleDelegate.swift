//
//  ZeroSettleDelegate.swift
//  ZeroSettleKit
//
//  Delegate protocol for IAP event callbacks.
//

import Foundation

// MARK: - ZeroSettle IAP Delegate

/// Delegate protocol to receive callbacks for ZeroSettle IAP events.
/// All methods have default empty implementations — only implement what you need.
///
/// ## Choosing an observation pattern
///
/// - **UIKit apps** — Implement this delegate for event-driven callbacks.
///   Best when you need to react to individual events (e.g., showing a toast on checkout completion).
///
/// - **SwiftUI apps** — Observe ``ZeroSettle/entitlements`` via `@ObservedObject`:
///   ```swift
///   @ObservedObject var zs = ZeroSettle.shared
///   // zs.entitlements is @Published and drives SwiftUI updates automatically.
///   ```
///
/// - **Structured concurrency** — Use ``ZeroSettle/entitlementUpdates`` (`AsyncStream`):
///   ```swift
///   for await entitlements in ZeroSettle.shared.entitlementUpdates {
///       updateUI(with: entitlements)
///   }
///   ```
@MainActor
public protocol ZeroSettleDelegate: AnyObject {

    // MARK: - Checkout Events
    //
    // Note: These callbacks are supplementary — checkout results are also returned
    // via the `purchase()` async method and the `checkoutSheet` completion handler.

    /// Called when a web checkout begins (Safari is opening).
    /// - Parameter productId: The product being purchased
    func zeroSettleCheckoutDidBegin(productId: String)

    /// Called when a web checkout completes successfully.
    /// - Parameter transaction: The completed transaction
    func zeroSettleCheckoutDidComplete(transaction: CheckoutTransaction)

    /// Called when the user cancels the web checkout (returns without purchasing).
    /// - Parameter productId: The product that was being purchased
    func zeroSettleCheckoutDidCancel(productId: String)

    /// Called when a web checkout fails.
    /// - Parameters:
    ///   - productId: The product that was being purchased
    ///   - error: The underlying error (``ZeroSettleError`` or ``PaymentSheetError``)
    func zeroSettleCheckoutDidFail(productId: String, error: Error)

    // MARK: - Entitlement Events

    /// Called when the user's entitlements are updated (from either source).
    ///
    /// - Note: For async/await code, prefer ``ZeroSettle/entitlementUpdates``
    ///   (`AsyncStream<[Entitlement]>`) over this delegate method.
    ///
    /// - Parameter entitlements: The updated list of all entitlements
    func zeroSettleEntitlementsDidUpdate(_ entitlements: [Entitlement])

    // MARK: - StoreKit Sync Events

    /// Called when a native StoreKit transaction is successfully synced to ZeroSettle.
    /// Only fired when `syncStoreKitTransactions` is enabled in the configuration.
    /// - Parameters:
    ///   - productId: The product ID of the synced transaction
    ///   - transactionId: The StoreKit transaction ID
    func zeroSettleDidSyncStoreKitTransaction(productId: String, transactionId: UInt64)

    /// Called when syncing a StoreKit transaction to ZeroSettle fails.
    /// - Parameter error: The underlying error. Concrete type is typically
    ///   ``ZeroSettleError/apiError(_:)`` wrapping the HTTP failure.
    func zeroSettleStoreKitSyncFailed(error: Error)
}

// MARK: - Default Implementations

public extension ZeroSettleDelegate {
    func zeroSettleCheckoutDidBegin(productId: String) {}
    func zeroSettleCheckoutDidComplete(transaction: CheckoutTransaction) {}
    func zeroSettleCheckoutDidCancel(productId: String) {}
    func zeroSettleCheckoutDidFail(productId: String, error: Error) {}
    func zeroSettleEntitlementsDidUpdate(_ entitlements: [Entitlement]) {}
    func zeroSettleDidSyncStoreKitTransaction(productId: String, transactionId: UInt64) {}
    func zeroSettleStoreKitSyncFailed(error: Error) {}
}
