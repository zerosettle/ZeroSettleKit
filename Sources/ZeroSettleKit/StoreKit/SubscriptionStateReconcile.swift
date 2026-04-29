import Foundation
import StoreKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// One entry from the subscription state reconcile payload.
internal struct SubscriptionStateEntry: Encodable {
    let signedTransaction: String
    let signedRenewalInfo: String?
}

/// Builds the bulk reconcile payload from the device's StoreKit state.
///
/// Iterates `Transaction.all` (which includes expired and revoked
/// transactions, unlike `currentEntitlements`). For each transaction in
/// a subscription product, looks up the corresponding
/// `Product.SubscriptionInfo.Status.renewalInfo` JWS via
/// `Product.SubscriptionInfo.status(for:)`.
///
/// Non-subscription transactions (consumables, non-consumables) are
/// included but without `signedRenewalInfo` (the backend ignores them
/// for state classification — they have no lifecycle).
internal struct SubscriptionStateReconciler {

    /// Gather all known StoreKit transactions + signed renewal infos.
    /// Bounded by Apple's `Transaction.all` cap (typically last 6 months).
    static func gather() async -> [SubscriptionStateEntry] {
        var entries: [SubscriptionStateEntry] = []
        var seenTransactionIDs: Set<UInt64> = []
        var renewalInfoByOTID: [UInt64: String] = [:]
        var queriedGroups: Set<String> = []

        // Pass 1: collect a renewal-info JWS per OTID we touch by querying
        // each unique subscription group exactly once.
        for await result in StoreKit.Transaction.all {
            guard let txn = try? result.payloadValue else { continue }
            guard let groupID = txn.subscriptionGroupID else { continue }
            if queriedGroups.contains(groupID) { continue }
            queriedGroups.insert(groupID)

            do {
                let statuses = try await Product.SubscriptionInfo.status(for: groupID)
                for status in statuses {
                    guard let statusTxn = try? status.transaction.payloadValue else { continue }
                    renewalInfoByOTID[statusTxn.originalID] = status.renewalInfo.jwsRepresentation
                }
            } catch {
                #if canImport(ZeroSettleCore)
                ZSLogger.warning(
                    "[storekit_recon] failed to fetch subscriptionStatus for group=\(groupID): \(error)",
                    category: .entitlements
                )
                #endif
            }
        }

        // Pass 2: build one entry per unique transaction ID.
        for await result in StoreKit.Transaction.all {
            guard let txn = try? result.payloadValue else { continue }
            if seenTransactionIDs.contains(txn.id) { continue }
            seenTransactionIDs.insert(txn.id)

            let signedRenewalInfo = renewalInfoByOTID[txn.originalID]
            entries.append(SubscriptionStateEntry(
                signedTransaction: result.jwsRepresentation,
                signedRenewalInfo: signedRenewalInfo
            ))
        }

        return entries
    }
}
