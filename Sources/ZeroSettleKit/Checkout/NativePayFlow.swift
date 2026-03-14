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
            }
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
        MainActor.assumeIsolated {
            guard let clientSecret = currentResponse?.clientSecret else {
                completion(nil, NativePay.PaymentError.missingClientSecret)
                return
            }
            completion(clientSecret, nil)
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
