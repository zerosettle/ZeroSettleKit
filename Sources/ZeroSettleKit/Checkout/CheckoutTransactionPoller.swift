//
//  CheckoutTransactionPoller.swift
//  ZeroSettleKit
//
//  Shared retry/timeout policy for polling a checkout transaction's terminal
//  state. Used by `WebCheckoutFlow.openInSafariVC` (legacy migration path)
//  and `ZSOfferManager.startCheckoutCompletionPoll` (unified offer path).
//  Each caller handles the `Outcome` according to its own state model.
//

import Foundation

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

@MainActor
internal enum CheckoutTransactionPoller {

    /// Result of a polling run. The caller decides what to do — `WebCheckoutFlow`
    /// dismisses the SafariVC on completion or failure; `ZSOfferManager` advances
    /// its state machine.
    enum Outcome {
        case completed(CheckoutTransaction)
        case failed(CheckoutTransaction)
        /// All attempts elapsed without reaching a terminal state, the
        /// `shouldContinue` predicate returned false, or the task was cancelled.
        case exhausted
    }

    /// Polls `backend.getTransaction(transactionId:)` until it reaches a terminal
    /// state, the `shouldContinue` predicate returns false, the task is cancelled,
    /// or the attempt budget is exhausted.
    ///
    /// Defaults match the previous inline-loop policy in both call sites:
    /// 3s initial delay, then 20 attempts × 2s. Network errors per attempt are
    /// swallowed so a transient blip doesn't abort polling.
    static func poll(
        transactionId: String,
        backend: Backend,
        shouldContinue: () -> Bool = { true },
        initialDelay: UInt64 = 3_000_000_000,
        interval: UInt64 = 2_000_000_000,
        maxAttempts: Int = 20
    ) async -> Outcome {
        try? await Task.sleep(nanoseconds: initialDelay)

        for _ in 1...maxAttempts {
            if Task.isCancelled { return .exhausted }
            if !shouldContinue() { return .exhausted }

            do {
                let txn = try await backend.getTransaction(transactionId: transactionId)
                switch txn.status {
                case .completed, .processing, .refunded:
                    return .completed(txn)
                case .failed:
                    return .failed(txn)
                case .pending:
                    break  // not yet terminal — keep polling
                }
            } catch {
                // Transient network failure — keep polling.
            }

            try? await Task.sleep(nanoseconds: interval)
        }
        return .exhausted
    }
}
