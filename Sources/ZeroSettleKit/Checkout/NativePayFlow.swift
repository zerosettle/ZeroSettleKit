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
        finalize: (String) async throws -> String
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
                behavior: ZeroSettle.shared.currentConfig?.applePaySetupBehavior ?? .presentBuiltInUI
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
            if let cached = await CheckoutResponseCache.shared.consume(productId: productId, userId: userId, publishableKey: pk) {
                response = cached
            } else {
                response = try await backend.initiateCheckout(
                    productId: productId, userId: userId
                )
            }

            self.currentResponse = response

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

// MARK: - ApplePayContextDelegate

extension NativePay.Flow: ApplePayContextDelegate {

    nonisolated func applePayContext(
        _ context: STPApplePayContext,
        didCreatePaymentMethod paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment,
        completion: @escaping STPIntentClientSecretCompletionBlock
    ) {
        Task { @MainActor in
            guard let response = self.currentResponse else {
                completion(nil, NativePay.PaymentError.missingClientSecret)
                return
            }
            // Deferred mode: finalize on user-tap to materialize the Stripe
            // Intent server-side. Legacy fall-through hits the cached branch
            // inside resolveClientSecret and short-circuits without a network
            // call. The closure captures `backend` so the resolver itself
            // stays a pure function of its inputs.
            let txnId = response.transactionId
            do {
                let clientSecret = try await NativePay.resolveClientSecret(
                    cached: response.clientSecret,
                    transactionId: txnId,
                    finalize: { [backend] id in
                        try await backend.finalizePaymentIntent(transactionId: id)
                    }
                )
                completion(clientSecret, nil)
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
                guard let transactionId = currentResponse?.transactionId else {
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
