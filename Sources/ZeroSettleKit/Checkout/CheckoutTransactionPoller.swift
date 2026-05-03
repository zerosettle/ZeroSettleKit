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
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif
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
        /// A non-transient HTTP error was returned (auth, missing transaction,
        /// publishable-key mismatch, etc). Polling stopped immediately because
        /// retrying won't help. The error is included so the caller can
        /// surface it to the developer / delegate.
        case terminalError(Error)
    }

    /// Polls `backend.getTransaction(transactionId:)` until it reaches a terminal
    /// state, the `shouldContinue` predicate returns false, the task is cancelled,
    /// or the attempt budget is exhausted.
    ///
    /// Defaults match the previous inline-loop policy in both call sites:
    /// 3s initial delay, then 20 attempts × 2s.
    ///
    /// Error classification (post-1.2.5):
    /// * **Transient** — network errors, decoding errors, 5xx, 429: keep polling.
    ///   These are usually fixable by waiting (backend slow, transient outage,
    ///   rate limit window).
    /// * **Terminal** — 4xx (excluding 429), invalidURL, invalidResponse: return
    ///   `.terminalError` immediately. These won't fix themselves: 401 means
    ///   the publishable key is wrong; 404 means the transaction doesn't exist
    ///   from the backend's perspective; 403 means access denied. Pre-1.2.5
    ///   we silently kept polling for 40+ seconds and returned `.exhausted` —
    ///   developers got a misleading "checkout abandoned" outcome instead of
    ///   the real reason.
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
            } catch let error as HTTPError {
                if isTerminal(error) {
                    ZSLogger.error(
                        "[CheckoutTransactionPoller] Terminal error polling transaction \(transactionId): \(error.localizedDescription). Stopping poll — retry won't help.",
                        category: .checkout
                    )
                    return .terminalError(error)
                }
                // Otherwise: transient (5xx, 429, network, decoding) — keep polling.
                ZSLogger.debug(
                    "[CheckoutTransactionPoller] Transient error polling transaction \(transactionId): \(error.localizedDescription). Will retry.",
                    category: .checkout
                )
            } catch {
                // Non-HTTPError: most likely cancellation or a Swift error.
                // Treat as transient — same behavior as pre-1.2.5.
                ZSLogger.debug(
                    "[CheckoutTransactionPoller] Transient error polling transaction \(transactionId): \(error.localizedDescription). Will retry.",
                    category: .checkout
                )
            }

            try? await Task.sleep(nanoseconds: interval)
        }
        return .exhausted
    }

    /// True if an HTTPError is a non-transient client-side problem that
    /// retrying won't fix. 4xx (except 429 rate-limit) is terminal; 5xx is
    /// transient; networking and decoding are transient.
    private static func isTerminal(_ error: HTTPError) -> Bool {
        switch error {
        case .httpError(let statusCode, _):
            // 429 (Too Many Requests) is retryable; any other 4xx is terminal.
            return statusCode >= 400 && statusCode < 500 && statusCode != 429
        case .invalidURL, .invalidResponse:
            return true
        case .networkError, .decodingFailed:
            return false
        }
    }
}
