//
//  StoreKitSyncQueue.swift
//  ZeroSettleKit
//
//  Persistent retry queue for failed StoreKit transaction syncs.
//  Uses UserDefaults so pending syncs survive app restarts.
//

import Foundation

#if canImport(ZeroSettleCore)
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif
#endif

// MARK: - StoreKit Sync Queue

/// A persistent retry queue for StoreKit transactions that failed to sync to the ZeroSettle backend.
///
/// When a StoreKit transaction is verified but the backend sync fails (e.g., due to network issues),
/// the transaction is enqueued here. On the next app launch (or manually via ``retryAll``), all
/// pending syncs are retried with exponential backoff.
///
/// Thread safety is guaranteed by the `actor` model.
internal actor StoreKitSyncQueue {

    // MARK: - Types

    /// A StoreKit transaction that failed to sync and is pending retry.
    struct PendingSync: Codable {
        /// The JWS representation of the StoreKit transaction.
        let jwsRepresentation: String
        /// The developer's user ID associated with the transaction.
        let userId: String
        /// The StoreKit transaction ID (used as a deduplication key).
        let transactionId: UInt64
        /// Number of sync attempts made so far.
        var attemptCount: Int
        /// Timestamp of the last sync attempt, if any.
        var lastAttemptAt: Date?
    }

    // MARK: - Constants

    private let key = "com.zerosettle.pending_storekit_syncs"

    /// Maximum number of retry attempts before giving up.
    private let maxAttempts = 5

    /// Exponential backoff delays in seconds, indexed by attemptCount (0-based).
    /// After the last value, the sync is abandoned.
    private let backoffDelays: [UInt64] = [1, 5, 30, 300]

    // MARK: - Persistence

    /// Load all pending syncs from UserDefaults.
    func pendingSyncs() -> [PendingSync] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }

        do {
            return try JSONDecoder().decode([PendingSync].self, from: data)
        } catch {
            ZSLogger.error("Failed to decode pending StoreKit syncs: \(error)", category: .entitlements)
            return []
        }
    }

    /// Persist the given syncs array to UserDefaults.
    private func save(_ syncs: [PendingSync]) {
        do {
            let data = try JSONEncoder().encode(syncs)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            ZSLogger.error("Failed to encode pending StoreKit syncs: \(error)", category: .entitlements)
        }
    }

    // MARK: - Queue Operations

    /// Add a failed sync to the retry queue.
    ///
    /// If a sync with the same `transactionId` already exists, it is replaced
    /// (the attempt count is preserved to avoid resetting backoff).
    func enqueue(_ sync: PendingSync) {
        var syncs = pendingSyncs()

        // Replace existing entry for the same transaction (preserve attempt count)
        if let existingIndex = syncs.firstIndex(where: { $0.transactionId == sync.transactionId }) {
            var updated = sync
            updated.attemptCount = syncs[existingIndex].attemptCount + 1
            updated.lastAttemptAt = Date()
            syncs[existingIndex] = updated
        } else {
            syncs.append(sync)
        }

        save(syncs)
        ZSLogger.info("Enqueued StoreKit sync retry for transaction \(sync.transactionId) (attempt \(sync.attemptCount))", category: .entitlements)
    }

    /// Remove a sync from the queue after it succeeds or is abandoned.
    func dequeue(_ transactionId: UInt64) {
        var syncs = pendingSyncs()
        syncs.removeAll { $0.transactionId == transactionId }
        save(syncs)
    }

    /// Drop every pending sync. Called by ``ZeroSettle/logout()`` so that
    /// transactions queued under a previous user don't get retried under a
    /// different user on the next launch (which would attribute User A's
    /// purchases to User B). The transactions remain unfinished in StoreKit
    /// — Apple will redeliver them via ``Transaction.updates`` once the next
    /// user identifies, at which point they'll be re-evaluated against the
    /// new ``userId``.
    func clearAll() {
        save([])
    }

    // MARK: - Retry

    /// Retry all pending syncs with exponential backoff.
    ///
    /// For each pending sync:
    /// - Waits for the appropriate backoff delay based on `attemptCount`
    /// - Calls `syncFn` with the JWS and userId
    /// - On success: dequeues the sync
    /// - On failure: increments `attemptCount` and saves
    /// - After ``maxAttempts``: dequeues the sync and logs a warning
    ///
    /// - Parameter syncFn: The async closure that performs the backend sync.
    ///   Typically `backend.syncStoreKitTransaction(jwsRepresentation:userId:)`.
    func retryAll(using syncFn: (String, String) async throws -> Void) async {
        let syncs = pendingSyncs()
        guard !syncs.isEmpty else { return }

        ZSLogger.info("Retrying \(syncs.count) pending StoreKit sync(s)", category: .entitlements)

        for sync in syncs {
            // Check if max attempts exceeded
            if sync.attemptCount >= maxAttempts {
                ZSLogger.error(
                    "Abandoning StoreKit sync for transaction \(sync.transactionId) after \(sync.attemptCount) attempts",
                    category: .entitlements
                )
                dequeue(sync.transactionId)
                continue
            }

            // Apply exponential backoff delay
            let delayIndex = min(sync.attemptCount, backoffDelays.count - 1)
            let delaySeconds = backoffDelays[delayIndex]
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)

            // Bail out if the task was cancelled (e.g., app is shutting down)
            guard !Task.isCancelled else { break }

            do {
                try await syncFn(sync.jwsRepresentation, sync.userId)
                dequeue(sync.transactionId)
                ZSLogger.info("Retry succeeded for StoreKit transaction \(sync.transactionId)", category: .entitlements)
            } catch {
                // Update attempt count and save
                var updated = sync
                updated.attemptCount += 1
                updated.lastAttemptAt = Date()

                var allSyncs = pendingSyncs()
                if let index = allSyncs.firstIndex(where: { $0.transactionId == sync.transactionId }) {
                    allSyncs[index] = updated
                }
                save(allSyncs)

                ZSLogger.error(
                    "Retry failed for StoreKit transaction \(sync.transactionId) (attempt \(updated.attemptCount)/\(maxAttempts)): \(error)",
                    category: .entitlements
                )
            }
        }
    }
}
