//
//  NativePayFlow.swift
//  ZeroSettleKit
//
//  Native Apple Pay checkout via Stripe's STPApplePayContext.
//  Only compiled when the `NativePay` package trait is enabled.
//

#if NativePay
import Foundation
import PassKit
import UIKit
import StripeApplePay

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - NativePay Namespace

/// Namespace for native Apple Pay checkout types.
/// Only available when the `NativePay` package trait is enabled.
public enum NativePay {

    /// Outcome of a native Apple Pay checkout attempt.
    public enum Result: Sendable {
        case success(CheckoutTransaction)
        case cancelled
    }

    /// Errors specific to the native Apple Pay checkout flow.
    public enum PaymentError: LocalizedError, Sendable {
        case applePayUnavailable
        case noViewController
        case missingClientSecret
        case missingTransactionId
        case alreadyInProgress
        case unknown
        /// The deferred-mode checkout config has expired (HTTP 410 from
        /// `/finalize/`). The user should restart checkout to obtain a fresh
        /// session. Mapped from `ZeroSettleError.checkoutConfigExpired` so the
        /// NativePay surface stays uniform.
        case checkoutConfigExpired
        /// Deferred-mode finalize returned a `seti_*` (SetupIntent) client
        /// secret. `STPApplePayContext` only supports PaymentIntent confirmation;
        /// trial flows via Apple Pay require a different STP API
        /// (`PKPaymentAuthorizationController` + `STPAPIClient.confirmSetupIntent`)
        /// and are tracked as a follow-up. The WebView path supports trials
        /// today.
        case trialViaApplePayNotSupported

        public var errorDescription: String? {
            switch self {
            case .applePayUnavailable:
                return "Apple Pay is not available on this device"
            case .noViewController:
                return "Unable to find a view controller to present Apple Pay"
            case .missingClientSecret:
                return "Missing payment intent client secret"
            case .missingTransactionId:
                return "Missing transaction ID"
            case .alreadyInProgress:
                return "A payment is already in progress"
            case .unknown:
                return "An unknown error occurred"
            case .checkoutConfigExpired:
                return "The checkout configuration has expired. Restart checkout to obtain a fresh session."
            case .trialViaApplePayNotSupported:
                return "Free trials via Apple Pay are not yet supported. Use the web checkout flow for trial offers."
            }
        }
    }
}

// MARK: - Client-secret resolver

extension NativePay {

    /// Resolve the Stripe client_secret to deliver to `STPApplePayContext`'s
    /// `didCreatePaymentMethod` completion block. Encapsulates the
    /// legacy-vs-deferred branching so the delegate stays small and the
    /// decision logic is straightforward to reason about (and to test once the
    /// `NativePay` trait is wired into a test scheme).
    ///
    /// - Parameters:
    ///   - cached: The `clientSecret` carried on the initial `CheckoutResponse`.
    ///       Non-nil on the legacy fall-through path; nil in deferred mode.
    ///   - transactionId: The deferred transaction id, used to call
    ///       `/finalize/` when `cached` is nil.
    ///   - finalize: Closure invoked in deferred mode to materialize the
    ///       Stripe Intent server-side. In production this wraps
    ///       `Backend.finalizePaymentIntent(transactionId:)`. Tests may stub it.
    /// - Returns: A PaymentIntent client_secret (`pi_*_secret_*`) suitable for
    ///     `STPApplePayContext`.
    /// - Throws:
    ///   - `PaymentError.trialViaApplePayNotSupported` when finalize returns a
    ///     `seti_*` (SetupIntent) secret — see the case doc for the rationale.
    ///   - `PaymentError.checkoutConfigExpired` when finalize throws
    ///     `ZeroSettleError.checkoutConfigExpired` (HTTP 410).
    ///   - Any other error thrown by `finalize` propagates unchanged.
    static func resolveClientSecret(
        cached: String?,
        transactionId: String,
        finalize: @Sendable (String) async throws -> String
    ) async throws -> String {
        if let cached, !cached.isEmpty {
            return cached
        }
        let secret: String
        do {
            secret = try await finalize(transactionId)
        } catch ZeroSettleError.checkoutConfigExpired {
            throw PaymentError.checkoutConfigExpired
        }
        if secret.hasPrefix("seti_") {
            throw PaymentError.trialViaApplePayNotSupported
        }
        return secret
    }

    /// The charge-shape the user authorized on the Apple Pay sheet. Used to
    /// detect a price/trial change after a 410 re-initiate so we never confirm
    /// a different amount than the one the user approved.
    ///
    /// `amount` is the charged amount in cents; for a free-trial it's the
    /// trial-time charge (0). `isTrial` distinguishes a $0-now-charge-later
    /// trial from a $0 actual price so a trial→non-trial flip (or vice versa)
    /// is treated as a mismatch even when both nominal amounts are 0.
    struct AuthorizedCharge: Equatable, Sendable {
        let transactionId: String
        let amount: Int
        let isTrial: Bool

        init(transactionId: String, amount: Int, isTrial: Bool) {
            self.transactionId = transactionId
            self.amount = amount
            self.isTrial = isTrial
        }

        /// Derive the authorized charge-shape from a `CheckoutResponse`.
        init(response: CheckoutResponse) {
            self.transactionId = response.transactionId
            self.isTrial = response.trialEnd != nil
            self.amount = response.amount
        }
    }

    /// Outcome of a recovery-capable client-secret resolution: the secret to
    /// confirm plus the transaction id it belongs to (which changes when a 410
    /// recovery re-initiated a fresh config). The caller updates its
    /// `currentResponse`/verification target from `effectiveTransactionId`.
    struct ResolvedSecret: Sendable {
        let clientSecret: String
        let effectiveTransactionId: String
    }

    /// Resolve the client_secret with single-retry recovery from a superseded /
    /// expired checkout config (HTTP 410 → ``ZeroSettleError/checkoutConfigExpired``).
    ///
    /// Always finalizes (never trusts a cached legacy `client_secret`) so the
    /// server-side freshness check runs: a config superseded by a dashboard QA
    /// variant override is SUPERSEDED on the backend and 410s at `/finalize/`,
    /// rather than confirming a stale secret. This closes the legacy-cached
    /// mischarge vector (issue #2). On a 410, it re-initiates the checkout ONCE
    /// to pick up the now-current variant and retries finalize against the fresh
    /// transaction (issue #1).
    ///
    /// Loop safety: the retry is a single straight-line step — no recursion, no
    /// loop — so a second 410 (or any error) on the re-initiated config
    /// propagates as ``PaymentError/checkoutConfigExpired`` instead of looping.
    ///
    /// Amount safety: by the time this runs the user has already authorized
    /// `authorized.amount` on the Apple Pay sheet. A TTL-only expiry re-resolves
    /// the same price (fine), but a variant override that *changes* the price or
    /// trial shape must NOT be silently confirmed at the new amount. If the
    /// re-initiated charge-shape differs from `authorized`, we throw
    /// ``PaymentError/checkoutConfigExpired`` so the next `pay()` re-presents the
    /// sheet at the correct price.
    ///
    /// - Parameters:
    ///   - authorized: The charge-shape the user approved on the Apple Pay sheet.
    ///   - finalize: Materializes the Stripe intent for a transaction id
    ///       (wraps `Backend.finalizePaymentIntent`). May throw
    ///       `ZeroSettleError.checkoutConfigExpired` on a 410.
    ///   - reinitiate: Invalidates the cached config and creates a fresh one,
    ///       returning the new authorized charge-shape. Called at most once.
    /// - Returns: The secret to confirm plus the transaction id it belongs to.
    static func resolveClientSecretWithRecovery(
        authorized: AuthorizedCharge,
        finalize: @Sendable (String) async throws -> String,
        reinitiate: @Sendable () async throws -> AuthorizedCharge
    ) async throws -> ResolvedSecret {
        // Each finalize attempt reuses the primitive resolver (cached: nil
        // forces finalize) so the seti_→trial and 410→checkoutConfigExpired
        // mapping lives in exactly one place.
        do {
            let secret = try await resolveClientSecret(
                cached: nil, transactionId: authorized.transactionId, finalize: finalize
            )
            return ResolvedSecret(clientSecret: secret, effectiveTransactionId: authorized.transactionId)
        } catch PaymentError.checkoutConfigExpired {
            // Single recovery attempt — re-resolve the now-current variant.
            let fresh = try await reinitiate()

            // Amount/trial guard: the user authorized `authorized`. If the fresh
            // config charges differently (a price/trial-changing override),
            // refuse to confirm and force a fresh sheet.
            guard fresh.amount == authorized.amount, fresh.isTrial == authorized.isTrial else {
                throw PaymentError.checkoutConfigExpired
            }

            // Retry finalize ONCE against the fresh transaction. A second 410
            // surfaces as checkoutConfigExpired from the primitive and is NOT
            // retried — straight-line, so recovery can never loop.
            let secret = try await resolveClientSecret(
                cached: nil, transactionId: fresh.transactionId, finalize: finalize
            )
            return ResolvedSecret(clientSecret: secret, effectiveTransactionId: fresh.transactionId)
        }
    }
}

// MARK: - NativePay.Flow

extension NativePay {

    /// Handles native Apple Pay checkout via STPApplePayContext.
    @MainActor
    internal final class Flow: NSObject {
        private let backend: Backend
        private var paymentContinuation: CheckedContinuation<NativePay.Result, Error>?
        private var currentResponse: CheckoutResponse?
        private var apiClient: STPAPIClient?
        // Captured at pay() time so the finalize delegate can re-initiate a
        // fresh checkout config on a 410 (superseded/expired) without plumbing
        // them through the STPApplePayContext callback.
        private var currentProductId: String?
        private var currentUserId: String?
        private var currentPublishableKey: String = ""
        // The transaction id whose intent we actually confirmed, set when the
        // client_secret resolves. Differs from the original when a 410 recovery
        // re-initiated a fresh config; `didCompleteWith` verifies THIS id so
        // post-pay verification targets the transaction that was charged.
        private var verificationTransactionId: String?

        init(backend: Backend) {
            self.backend = backend
            super.init()
        }

        /// Whether the device supports Apple Pay.
        func canMakePayments() -> Bool {
            StripeAPI.deviceSupportsApplePay()
        }

        /// Present the native Apple Pay sheet for a product purchase.
        func pay(
            productId: String,
            userId: String?,
            merchantId: String
        ) async throws -> NativePay.Result {
            // Pre-flight: when the merchant is Apple-Pay-only, refuse to
            // present the Apple Pay sheet if the device cannot complete the
            // purchase. STPApplePayContext silently no-ops on .unavailable
            // and shows an unhelpful sheet on .setupRequired — surface the
            // typed error before either happens. Honors .presentBuiltInUI by
            // opening system Wallet automatically before throwing.
            let outcome = ApplePayPreflightGate.evaluate(
                isApplePayOnly: ZeroSettle.shared.isApplePayOnly,
                state: ZeroSettle.shared.applePayAvailability.state,
                behavior: ZeroSettle.shared.resolvedApplePaySetupBehavior
            )
            if case .blocked(let error, let openSetupUI) = outcome {
                ZSLogger.info("[NativePay] pay blocked — error=\(error) openSetupUI=\(openSetupUI)", category: .checkout)
                if openSetupUI {
                    ZeroSettle.shared.presentApplePaySetup()
                }
                throw error
            }

            // 1. Initiate checkout — use cached response if available (from preloading)
            let pk = ZeroSettle.shared.currentConfig?.publishableKey ?? ""
            let response: CheckoutResponse
            let fingerprint = ZeroSettle.shared.checkoutVariantFingerprint(for: productId)
            if let cached = await CheckoutResponseCache.shared.consume(productId: productId, userId: userId, publishableKey: pk, variantFingerprint: fingerprint) {
                response = cached
            } else {
                // interactive: pay() runs in direct response to the user's
                // buy action (the Apple Pay sheet presents next).
                response = try await backend.initiateCheckout(
                    productId: productId, userId: userId, interactive: true
                )
            }

            self.currentResponse = response
            self.currentProductId = productId
            self.currentUserId = userId
            self.currentPublishableKey = pk

            // 2. Configure a dedicated Stripe API client
            let client = STPAPIClient()
            client.publishableKey = response.publishableKey
            if let stripeAccount = response.stripeAccount {
                client.stripeAccount = stripeAccount
            }
            self.apiClient = client

            // 3. Build PKPaymentRequest via Stripe helper
            let paymentRequest = StripeAPI.paymentRequest(
                withMerchantIdentifier: merchantId,
                country: response.merchantCountry ?? "US",
                currency: response.currency.uppercased()
            )

            let isTrial = response.trialEnd != nil
            let displayAmount: NSDecimalNumber
            let summaryItemType: PKPaymentSummaryItemType

            if isTrial, let pendingAmount = response.pendingAmount, pendingAmount > 0 {
                // Free trial: show the subscription price as pending (card saved, charged later)
                displayAmount = NSDecimalNumber(value: pendingAmount).dividing(by: 100)
                summaryItemType = .pending
            } else {
                displayAmount = NSDecimalNumber(value: response.amount).dividing(by: 100)
                summaryItemType = .final
            }

            var summaryItems = [
                PKPaymentSummaryItem(label: response.productName, amount: displayAmount, type: summaryItemType),
            ]

            // Recurring payment disclosure for subscriptions (iOS 16+)
            if response.isSubscription == true, let interval = response.subscriptionInterval {
                if #available(iOS 16.0, *) {
                    let recurring = PKRecurringPaymentRequest(
                        paymentDescription: response.productName,
                        regularBilling: PKRecurringPaymentSummaryItem(
                            label: response.productName, amount: displayAmount
                        ),
                        managementURL: URL(string: "https://zerosettle.io/manage")!
                    )
                    recurring.regularBilling.intervalUnit = Self.calendarUnit(from: interval)
                    recurring.regularBilling.intervalCount = 1
                    paymentRequest.recurringPaymentRequest = recurring
                }
            }

            summaryItems.append(
                PKPaymentSummaryItem(label: "ZeroSettle", amount: displayAmount, type: summaryItemType)
            )
            paymentRequest.paymentSummaryItems = summaryItems
            paymentRequest.requiredBillingContactFields = [.postalAddress]

            // 4. Present Apple Pay sheet
            guard let applePayContext = STPApplePayContext(
                paymentRequest: paymentRequest, delegate: self
            ) else {
                throw NativePay.PaymentError.applePayUnavailable
            }

            guard let topVC = Self.topViewController() else {
                throw NativePay.PaymentError.noViewController
            }

            return try await withCheckedThrowingContinuation { continuation in
                guard self.paymentContinuation == nil else {
                    continuation.resume(throwing: NativePay.PaymentError.alreadyInProgress)
                    return
                }
                self.paymentContinuation = continuation
                applePayContext.presentApplePay(on: topVC)
            }
        }

        // MARK: - 410 recovery

        /// Re-initiate the checkout config after a 410 (superseded/expired) to
        /// pick up the now-current variant. Invalidates the cached config first
        /// so a stale entry can't be re-served, then creates a fresh one and
        /// promotes it to `currentResponse` (so post-pay verification targets
        /// the new transaction). Returns the fresh authorized charge-shape for
        /// the amount guard. Called at most once per pay() (see
        /// ``NativePay/resolveClientSecretWithRecovery(authorized:finalize:reinitiate:)``).
        private func reinitiateAfterExpiry() async throws -> NativePay.AuthorizedCharge {
            guard let productId = currentProductId else {
                // No captured product context — can't recover. Surface as expiry.
                throw NativePay.PaymentError.checkoutConfigExpired
            }
            let userId = currentUserId
            let fingerprint = ZeroSettle.shared.checkoutVariantFingerprint(for: productId)
            await CheckoutResponseCache.shared.invalidate(
                productId: productId, userId: userId,
                publishableKey: currentPublishableKey,
                variantFingerprint: fingerprint
            )
            ZSLogger.info("[NativePay] checkout config expired (410) — re-initiating once for \(productId)", category: .checkout)
            let fresh = try await backend.initiateCheckout(
                productId: productId, userId: userId, interactive: true
            )
            self.currentResponse = fresh
            return NativePay.AuthorizedCharge(response: fresh)
        }

        // MARK: - Helpers

        private static func calendarUnit(from interval: String) -> NSCalendar.Unit {
            switch interval {
            case "week": return .weekOfMonth
            case "month": return .month
            case "year": return .year
            default: return .month
            }
        }

        private static func topViewController() -> UIViewController? {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            else { return nil }

            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            return topVC
        }
    }
}

// MARK: - Unchecked Sendable Box

/// Wraps a non-Sendable value so it can be captured into a `Task` under Swift 6
/// strict concurrency. Used to carry Stripe's non-Sendable
/// `STPIntentClientSecretCompletionBlock` from a `nonisolated` delegate callback
/// into the `@MainActor` Task that resolves the client secret. Safe ONLY because
/// the boxed value is read and used exclusively on the main actor (the delegate
/// is invoked on the main thread and the completion is called on MainActor) — it
/// never actually crosses threads.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - ApplePayContextDelegate

extension NativePay.Flow: ApplePayContextDelegate {

    nonisolated func applePayContext(
        _ context: STPApplePayContext,
        didCreatePaymentMethod paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment,
        completion: @escaping STPIntentClientSecretCompletionBlock
    ) {
        // `completion` is Stripe's non-Sendable `STPIntentClientSecretCompletionBlock`.
        // Under Swift 6 strict concurrency, capturing it into a `Task { @MainActor }`
        // is a "sending non-Sendable value" error. STPApplePayContext invokes
        // this delegate on the main thread (per Stripe's contract), and we only
        // ever call `completion` on the MainActor, so wrapping it in an
        // @unchecked Sendable box is safe: the box never escapes the main actor.
        let box = UncheckedSendableBox(completion)
        Task { @MainActor in
            let completion = box.value
            guard let response = self.currentResponse else {
                completion(nil, NativePay.PaymentError.missingClientSecret)
                return
            }
            // Always finalize on user-tap — never confirm a cached legacy
            // `client_secret` directly. The /finalize/ round-trip is the
            // freshness check: a config superseded by a dashboard variant
            // override is SUPERSEDED server-side and 410s here instead of
            // confirming a stale price (issue #2). For a non-superseded legacy
            // txn finalize is idempotent and returns the same secret. On a 410,
            // resolveClientSecretWithRecovery re-initiates ONCE and retries
            // (issue #1); the re-initiate promotes the fresh response to
            // `currentResponse` so didCompleteWith verifies the right txn.
            let authorized = NativePay.AuthorizedCharge(response: response)
            do {
                let resolved = try await NativePay.resolveClientSecretWithRecovery(
                    authorized: authorized,
                    finalize: { @Sendable [backend] id in
                        try await backend.finalizePaymentIntent(transactionId: id)
                    },
                    reinitiate: { @Sendable [weak self] in
                        guard let self else { throw NativePay.PaymentError.checkoutConfigExpired }
                        return try await self.reinitiateAfterExpiry()
                    }
                )
                // Record the txn id the resolved secret belongs to (the fresh
                // one after a 410 recovery) so didCompleteWith verifies it.
                self.verificationTransactionId = resolved.effectiveTransactionId
                completion(resolved.clientSecret, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    nonisolated func applePayContext(
        _ context: STPApplePayContext,
        didCompleteWith status: STPApplePayContext.PaymentStatus,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            switch status {
            case .success:
                // Prefer the resolved verification id (the fresh txn after a 410
                // recovery); fall back to the current response for the common
                // no-recovery path. Both are the same when no recovery occurred.
                guard let transactionId = verificationTransactionId ?? currentResponse?.transactionId else {
                    paymentContinuation?.resume(throwing: NativePay.PaymentError.missingTransactionId)
                    paymentContinuation = nil
                    return
                }
                // Capture and nil out continuation immediately to prevent races
                let continuation = paymentContinuation
                paymentContinuation = nil
                Task { @MainActor [backend] in
                    do {
                        let transaction = try await backend.verifyTransaction(transactionId: transactionId)
                        continuation?.resume(returning: .success(transaction))
                    } catch {
                        continuation?.resume(throwing: error)
                    }
                }

            case .error:
                paymentContinuation?.resume(throwing: error ?? NativePay.PaymentError.unknown)
                paymentContinuation = nil

            case .userCancellation:
                paymentContinuation?.resume(returning: .cancelled)
                paymentContinuation = nil

            @unknown default:
                paymentContinuation?.resume(throwing: NativePay.PaymentError.unknown)
                paymentContinuation = nil
            }
        }
    }
}

#endif // NativePay
