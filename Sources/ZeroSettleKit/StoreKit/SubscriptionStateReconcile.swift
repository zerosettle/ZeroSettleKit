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

/// One StoreKit transaction reduced to the fields the reconcile selection
/// needs, so selection and filtering can be unit tested without StoreKit.
internal struct ReconcileCandidate: Equatable {
    let id: UInt64
    let originalID: UInt64
    let purchaseDate: Date
    let appAccountToken: UUID?
    let signedTransaction: String
    let signedRenewalInfo: String?
    /// `nil` for consumables and non-consumables.
    let subscriptionGroupID: String?

    var entry: SubscriptionStateEntry {
        SubscriptionStateEntry(
            signedTransaction: signedTransaction,
            signedRenewalInfo: signedRenewalInfo
        )
    }
}

/// Builds the bulk reconcile payload from the device's StoreKit state.
///
/// The backend only needs the current state of each subscription, not its
/// history, so the payload is kept small:
/// - Subscriptions: one entry per `Product.SubscriptionInfo.status(for:)`
///   status (the latest transaction plus its signed renewal info). Any
///   subscription original transaction ID that no status entry covers (the
///   status call threw, returned nothing, failed verification, or omitted that
///   ID) falls back to its latest `Transaction.all` transaction, without
///   renewal info.
/// - Non-subscriptions (consumables, non-consumables): one entry per
///   transaction from `Transaction.all`, without renewal info, so refunds
///   still reach the backend.
/// - Entries whose `appAccountToken` belongs to a different user are dropped.
internal struct SubscriptionStateReconciler {

    /// Gather the StoreKit transactions and signed renewal infos to reconcile.
    static func gather(userId: String) async -> [SubscriptionStateEntry] {
        var all: [ReconcileCandidate] = []
        for await result in StoreKit.Transaction.all {
            guard let txn = try? result.payloadValue else { continue }
            all.append(ReconcileCandidate(
                id: txn.id,
                originalID: txn.originalID,
                purchaseDate: txn.purchaseDate,
                appAccountToken: txn.appAccountToken,
                signedTransaction: result.jwsRepresentation,
                signedRenewalInfo: nil,
                subscriptionGroupID: txn.subscriptionGroupID
            ))
        }

        var statusesByGroup: [String: [ReconcileCandidate]] = [:]
        for groupID in Set(all.compactMap(\.subscriptionGroupID)) {
            do {
                let statuses = try await Product.SubscriptionInfo.status(for: groupID)
                statusesByGroup[groupID] = statuses.compactMap { status in
                    guard let txn = try? status.transaction.payloadValue else { return nil }
                    return ReconcileCandidate(
                        id: txn.id,
                        originalID: txn.originalID,
                        purchaseDate: txn.purchaseDate,
                        appAccountToken: txn.appAccountToken,
                        signedTransaction: status.transaction.jwsRepresentation,
                        signedRenewalInfo: status.renewalInfo.jwsRepresentation,
                        subscriptionGroupID: groupID
                    )
                }
            } catch {
                #if canImport(ZeroSettleCore)
                ZSLogger.error(
                    "[storekit_recon] failed to fetch subscriptionStatus for group=\(groupID): \(error)",
                    category: .entitlements
                )
                #endif
            }
        }

        let selected = select(transactions: all, statusesByGroup: statusesByGroup)
        let expected = expectedToken(userId: userId, bundleId: Bundle.main.bundleIdentifier)
        return dropForeign(selected, expectedToken: expected).map(\.entry)
    }

    // MARK: - Pure selection

    /// Picks what to send. Status entries are used as-is. Every subscription
    /// original ID not covered by a status entry falls back to its latest
    /// transaction, whatever the reason (call threw, empty or unverified list,
    /// ID omitted). Non-subscriptions pass through.
    static func select(
        transactions: [ReconcileCandidate],
        statusesByGroup: [String: [ReconcileCandidate]]
    ) -> [ReconcileCandidate] {
        let statusEntries = dedupedByID(statusesByGroup.keys.sorted().flatMap { statusesByGroup[$0] ?? [] })
        let covered = Set(statusEntries.map(\.originalID))
        let uncoveredTxns = transactions.filter {
            $0.subscriptionGroupID != nil && !covered.contains($0.originalID)
        }
        let nonSubscriptions = dedupedByID(transactions.filter { $0.subscriptionGroupID == nil })
        return statusEntries + latestPerOriginalID(uncoveredTxns) + nonSubscriptions
    }

    /// First occurrence of each transaction ID wins.
    static func dedupedByID(_ candidates: [ReconcileCandidate]) -> [ReconcileCandidate] {
        var seen: Set<UInt64> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }

    /// Latest transaction per original ID: greatest `purchaseDate`, ties by greater `id`.
    static func latestPerOriginalID(_ candidates: [ReconcileCandidate]) -> [ReconcileCandidate] {
        var latest: [UInt64: ReconcileCandidate] = [:]
        for candidate in candidates {
            guard let current = latest[candidate.originalID] else {
                latest[candidate.originalID] = candidate
                continue
            }
            if candidate.purchaseDate > current.purchaseDate
                || (candidate.purchaseDate == current.purchaseDate && candidate.id > current.id) {
                latest[candidate.originalID] = candidate
            }
        }
        return latest.values.sorted { $0.id < $1.id }
    }

    // MARK: - Foreign-token filter

    /// The token this user's purchases carry, or `nil` when it cannot be
    /// derived (`derive` preconditions on empty inputs).
    static func expectedToken(userId: String?, bundleId: String?) -> UUID? {
        guard let userId, !userId.isEmpty, let bundleId, !bundleId.isEmpty else { return nil }
        return AppAccountToken.derive(userId: userId, bundleId: bundleId)
    }

    /// Drops entries whose `appAccountToken` is set and differs from
    /// `expectedToken`. Runs after selection so an older matching transaction
    /// never replaces a newer foreign one. A `nil` expected token keeps all.
    static func dropForeign(
        _ candidates: [ReconcileCandidate],
        expectedToken: UUID?
    ) -> [ReconcileCandidate] {
        guard let expectedToken else { return candidates }
        return candidates.filter { $0.appAccountToken == nil || $0.appAccountToken == expectedToken }
    }
}
