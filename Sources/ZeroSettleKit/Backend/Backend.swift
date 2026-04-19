//
//  Backend.swift
//  ZeroSettleKit
//
//  Internal API client for ZeroSettle IAP endpoints.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Backend

/// Internal API client for ZeroSettle IAP endpoints.
/// Authenticates requests using the developer's publishable key.
internal final class Backend: @unchecked Sendable {
    private let baseURL: URL
    private let publishableKey: String
    private let httpClient: HTTPClient
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, publishableKey: String) {
        self.baseURL = baseURL
        self.publishableKey = publishableKey

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase

        self.httpClient = HTTPClient(decoder: decoder, encoder: encoder)
    }

    // MARK: - Auth Headers

    private var authHeaders: [String: String] {
        ["X-ZeroSettle-Key": publishableKey]
    }

    // MARK: - Products

    /// Fetch the product catalog for this developer's app.
    /// - Parameter userId: Optional user ID to check for migration eligibility
    /// - Returns: A ``ProductCatalog`` containing products and remote configuration
    func fetchProducts(userId: String? = nil) async throws -> ProductCatalog {
        var components = URLComponents(url: apiURL("iap/products/"), resolvingAgainstBaseURL: false)!
        if let userId {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        }

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct products URL"))
        }

        let response: ProductsResponse
        do {
            response = try await httpClient.get(
                url,
                headers: authHeaders,
                responseType: ProductsResponse.self
            )
        } catch {
            throw Backend.wrapError(error)
        }

        // Parse remote config if present
        let remoteConfig: RemoteConfig?
        if let configResponse = response.config {
            let checkoutType: CheckoutType
            if let parsed = CheckoutType(rawValue: configResponse.checkout.sheetType) {
                checkoutType = parsed
            } else {
                checkoutType = .webView
                ZSLogger.info("Unrecognized checkout type '\(configResponse.checkout.sheetType)' from backend, defaulting to webView. You may need to update ZeroSettleKit.", category: .network)
            }

            // Parse jurisdiction overrides
            var jurisdictions: [Jurisdiction: JurisdictionCheckoutConfig] = [:]
            if let jurDict = configResponse.checkout.jurisdictions {
                for (key, value) in jurDict {
                    guard let jurisdiction = Jurisdiction(rawValue: key) else { continue }
                    let sheetType: CheckoutType
                    if let parsed = CheckoutType(rawValue: value.sheetType) {
                        sheetType = parsed
                    } else {
                        sheetType = .webView
                        ZSLogger.info("Unrecognized checkout type '\(value.sheetType)' for jurisdiction \(key), defaulting to webView.", category: .network)
                    }
                    jurisdictions[jurisdiction] = JurisdictionCheckoutConfig(
                        sheetType: sheetType,
                        isEnabled: value.isEnabled
                    )
                }
            }

            let checkoutConfig = CheckoutConfig(
                sheetType: checkoutType,
                isEnabled: configResponse.checkout.isEnabled,
                jurisdictions: jurisdictions,
                appleMerchantId: configResponse.checkout.appleMerchantId
            )

            let migration: MigrationPrompt?
            if let migrationResponse = configResponse.migration {
                let eligible = migrationResponse.eligibleProductIds ?? []

                if migrationResponse.shouldShow,
                   let discountPercent = migrationResponse.discountPercent,
                   let title = migrationResponse.title,
                   let message = migrationResponse.message {
                    let perProductData = migrationResponse.perProductPrompts?.mapValues { pp in
                        MigrationPrompt.PerProductData(
                            discountPercent: pp.discountPercent,
                            title: pp.title,
                            message: pp.message,
                            ctaText: pp.ctaText ?? "Switch Now"
                        )
                    }
                    migration = MigrationPrompt(
                        productId: eligible.first ?? "",
                        eligibleProductIds: eligible,
                        discountPercent: discountPercent,
                        minSubscriptionDays: migrationResponse.minSubscriptionDays ?? 0,
                        maxSubscriptionDays: migrationResponse.maxSubscriptionDays,
                        freeTrialDays: migrationResponse.freeTrialDays ?? 0,
                        title: title,
                        message: message,
                        ctaText: migrationResponse.ctaText ?? "Switch Now",
                        rolloutPercent: migrationResponse.rolloutPercent,
                        perProductPrompts: perProductData
                    )
                } else {
                    migration = nil
                }
            } else {
                migration = nil
            }

            remoteConfig = RemoteConfig(checkout: checkoutConfig, migration: migration, offer: configResponse.offer)
        } else {
            remoteConfig = nil
        }

        return ProductCatalog(products: response.products, config: remoteConfig)
    }

    // MARK: - Checkout Sessions

    /// Create a Stripe checkout session for the given product and user.
    /// The backend creates the session via the developer's connected Stripe Express account.
    /// - Parameters:
    ///   - productId: The product ID to create a checkout session for
    ///   - userId: Optional user ID (for managed user identity scenario)
    ///   - externalUserId: Optional external user ID
    ///   - rcAppUserId: Optional RevenueCat app user ID
    func createCheckoutSession(
        productId: String,
        userId: String? = nil,
        externalUserId: String? = nil,
        rcAppUserId: String? = nil
    ) async throws -> CheckoutSession {
        let url = apiURL("iap/checkout-sessions/")
        let (name, email) = await MainActor.run {
            (ZeroSettle.shared.customerName, ZeroSettle.shared.customerEmail)
        }
        let body = CreateCheckoutSessionRequest(
            productId: productId,
            userId: userId,
            externalUserId: externalUserId,
            rcAppUserId: rcAppUserId,
            customerName: name,
            customerEmail: email
        )
        return try await httpClient.post(
            url,
            body: body,
            headers: authHeaders,
            responseType: CheckoutSession.self
        )
    }

    // MARK: - Checkout

    /// Initiate a checkout for the given product.
    /// The backend creates the Transaction, PaymentIntent/SetupIntent, and returns a `checkoutUrl`.
    func initiateCheckout(productId: String, userId: String? = nil, stripeCustomerId: String? = nil, storekitSubscriptionEnd: Date? = nil, storekitOriginalTransactionId: String? = nil, checkoutMode: String? = nil, externalPurchaseToken: String? = nil) async throws -> CheckoutResponse {
        let url = apiURL("iap/payment-intents/")
        let iso8601End: String? = storekitSubscriptionEnd.map {
            $0.formatted(.iso8601)
        }
        // Auto-detect the active StoreKit subscription's originalTransactionId
        // when not explicitly provided.  Scoped to the same subscription group
        // as the product being purchased so multi-group apps resolve correctly.
        // The backend uses this to query Apple's App Store Server API for the
        // real expiry and apply a migration trial automatically.
        var resolvedOriginalTxnId = storekitOriginalTransactionId
        if resolvedOriginalTxnId == nil {
            resolvedOriginalTxnId = await MainActor.run {
                guard let targetProduct = ZeroSettle.shared.product(for: productId),
                      let groupId = targetProduct.subscriptionGroupId else { return nil }
                let groupProductIds = Set(ZeroSettle.shared.products
                    .filter { $0.subscriptionGroupId == groupId }
                    .map { $0.id })
                return ZeroSettle.shared.entitlements
                    .first(where: {
                        $0.source == .storeKit &&
                        $0.isActive &&
                        $0.storekitOriginalTransactionId != nil &&
                        groupProductIds.contains($0.productId)
                    })?
                    .storekitOriginalTransactionId
            }
        }
        let (custName, custEmail) = await MainActor.run {
            (ZeroSettle.shared.customerName, ZeroSettle.shared.customerEmail)
        }
        // Device iOS version — feeds the backend's Apple auto-reporting
        // regime detector (Japan MSCA requires iOS 26.4+). UIKit is always
        // available on iOS; guarded here for non-iOS build targets.
        let iosVersion: String?
        #if canImport(UIKit)
        iosVersion = await MainActor.run { UIDevice.current.systemVersion }
        #else
        iosVersion = nil
        #endif
        let body = InitiateCheckoutRequest(
            productId: productId,
            userId: userId,
            stripeCustomerId: stripeCustomerId,
            storekitSubscriptionEnd: iso8601End,
            storekitOriginalTransactionId: resolvedOriginalTxnId,
            checkoutMode: checkoutMode,
            customerName: custName,
            customerEmail: custEmail,
            externalPurchaseToken: externalPurchaseToken,
            iosVersion: iosVersion
        )
        do {
            return try await httpClient.post(url, body: body, headers: authHeaders, responseType: CheckoutResponse.self)
        } catch let error as HTTPError {
            // Retry once on 409 with retry_after — server says a concurrent request
            // (e.g. batch) is creating this PI right now.  Wait then retry; the
            // server's dedup will return the completed transaction.
            if case .httpError(statusCode: 409, body: let data) = error,
               let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawDelay = json["retry_after"] as? Double {
                let retryDelay = min(max(rawDelay, 0.1), 5.0)
                ZSLogger.info("[Backend] PI in-flight for \(productId), retrying in \(retryDelay)s", category: .checkout)
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                return try await wrapped {
                    try await httpClient.post(url, body: body, headers: authHeaders, responseType: CheckoutResponse.self)
                }
            }
            throw Self.wrapError(error)
        } catch {
            throw Self.wrapError(error)
        }
    }

    /// Initiate checkouts for multiple products in a single request.
    /// Shares expensive work (Stripe customer, connect account) across all products.
    func initiateCheckoutBatch(products: [BatchCheckoutRequest.ProductEntry], userId: String? = nil, stripeCustomerId: String? = nil) async throws -> BatchCheckoutResponse {
        let url = apiURL("iap/payment-intents/batch/")
        let (batchName, batchEmail) = await MainActor.run {
            (ZeroSettle.shared.customerName, ZeroSettle.shared.customerEmail)
        }
        let body = BatchCheckoutRequest(products: products, userId: userId, stripeCustomerId: stripeCustomerId, customerName: batchName, customerEmail: batchEmail)
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: BatchCheckoutResponse.self)
        }
    }

    // MARK: - Transactions

    /// Get the status of a transaction by ID.
    func getTransaction(transactionId: String) async throws -> CheckoutTransaction {
        let url = apiURL("iap/transactions/\(transactionId)/")
        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: CheckoutTransaction.self)
        }
    }

    /// Update the StoreKit subscription status on a transaction.
    func updateStorekitStatus(transactionId: String, storekitStatus: Int, storekitSubscriptionEnd: Date? = nil) async throws {
        let url = apiURL("iap/transactions/\(transactionId)/storekit-status/")
        let body = UpdateStorekitStatusRequest(storekitStatus: storekitStatus, storekitSubscriptionEnd: storekitSubscriptionEnd)
        try await wrapped { try await httpClient.patchVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - Transaction Verification

    /// Poll the backend to verify a transaction has completed.
    ///
    /// Waits an initial 1.5s for webhook processing, then polls `getTransaction()`
    /// up to `maxAttempts` times. Returns the transaction on `.completed` or
    /// `.processing` (final attempt), throws on pending/failed or timeout.
    func verifyTransaction(
        transactionId: String,
        maxAttempts: Int = 6,
        pollInterval: UInt64 = 2_000_000_000
    ) async throws -> CheckoutTransaction {
        // Initial delay for webhook processing
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var lastTransaction: CheckoutTransaction?
        for attempt in 1...maxAttempts {
            let transaction = try await getTransaction(transactionId: transactionId)
            lastTransaction = transaction

            switch transaction.status {
            case .completed:
                return transaction
            case .processing, .pending:
                // Webhook may still be processing — keep polling
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    continue
                }
                // Final attempt: processing is success-like, pending means webhook never arrived
                if transaction.status == .processing {
                    return transaction
                }
                throw PaymentSheetError.verificationTimedOut
            default:
                // .failed, .refunded — terminal error states
                throw PaymentSheetError.transactionFailed(status: transaction.status.rawValue)
            }
        }
        if let txn = lastTransaction { return txn }
        throw PaymentSheetError.verificationFailed("Verification timed out")
    }

    // MARK: - Entitlements

    /// Get the current entitlements for a user.
    func getEntitlements(userId: String) async throws -> [Entitlement] {
        var components = URLComponents(url: apiURL("iap/entitlements/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct entitlements URL"))
        }

        let response: EntitlementsResponse = try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: EntitlementsResponse.self)
        }
        return response.entitlements
    }

    // MARK: - Transaction History

    /// Get all transactions for a user (including consumed, expired, refunded).
    func getTransactionHistory(userId: String) async throws -> [CheckoutTransaction] {
        var components = URLComponents(url: apiURL("iap/transaction-history/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct transaction history URL"))
        }

        let response: TransactionHistoryResponse = try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: TransactionHistoryResponse.self)
        }
        return response.transactions
    }

    // MARK: - Migration Tracking

    /// Track a successful migration conversion (user switched from StoreKit to web checkout).
    func trackMigrationConversion(userId: String) async throws {
        let url = apiURL("iap/migration-converted/")
        let body = MigrationConversionRequest(userId: userId)
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - StoreKit Transaction Sync

    /// Forward a StoreKit transaction's JWS representation for server-side verification.
    /// Returns ownership info: `owned` is true if this transaction belongs to the current user.
    func syncStoreKitTransaction(jwsRepresentation: String, userId: String) async throws -> SyncStoreKitTransactionResponse {
        let url = apiURL("iap/storekit-transactions/")
        let body = SyncStoreKitTransactionRequest(
            jwsRepresentation: jwsRepresentation,
            userId: userId
        )
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: SyncStoreKitTransactionResponse.self)
        }
    }

    /// Explicitly claim a StoreKit entitlement for the current user, even if
    /// another ZeroSettle account originally purchased it on this Apple ID.
    func claimEntitlement(jwsRepresentation: String, userId: String) async throws -> ClaimEntitlementResponse {
        let url = apiURL("iap/claim-entitlement/")
        let body = SyncStoreKitTransactionRequest(
            jwsRepresentation: jwsRepresentation,
            userId: userId
        )
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: ClaimEntitlementResponse.self)
        }
    }

    // MARK: - Cancel Flow

    /// Fetch the cancel flow configuration for this app.
    /// - Parameter userId: Optional user ID for A/B experiment targeting
    func fetchCancelFlow(userId: String? = nil) async throws -> CancelFlow.Config {
        var components = URLComponents(url: apiURL("iap/cancel-flow/"), resolvingAgainstBaseURL: false)!
        if let userId {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        }

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct cancel flow URL"))
        }

        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: CancelFlow.Config.self)
        }
    }

    /// Submit a cancel flow response (fire-and-forget from the caller's perspective).
    func submitCancelFlowResponse(_ payload: CancelFlow.ResponsePayload) async throws {
        let url = apiURL("iap/cancel-flow/respond/")
        try await wrapped { try await httpClient.postVoid(url, body: payload, headers: authHeaders) }
    }

    /// Accept the save offer for a cancel flow, applying the discount on Stripe.
    func acceptSaveOffer(productId: String, userId: String) async throws -> AcceptSaveOfferResponse {
        let url = apiURL("iap/cancel-flow/accept-offer/")
        let body = AcceptSaveOfferRequest(productId: productId, userId: userId)
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: AcceptSaveOfferResponse.self)
        }
    }

    // MARK: - Subscription Pause/Resume/Cancel

    /// Pause a subscription for the given product and user.
    /// - Parameters:
    ///   - productId: The product to pause
    ///   - userId: The user who owns the subscription
    ///   - pauseDurationDays: Number of days to pause, or nil for indefinite
    /// - Returns: A ``PauseSubscriptionResponse`` with the resume date
    func pauseSubscription(productId: String, userId: String, pauseDurationDays: Int?) async throws -> PauseSubscriptionResponse {
        let url = apiURL("iap/subscriptions/pause/")
        let body = PauseSubscriptionRequest(productId: productId, userId: userId, pauseDurationDays: pauseDurationDays)
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: PauseSubscriptionResponse.self)
        }
    }

    /// Resume a paused subscription.
    func resumeSubscription(productId: String, userId: String) async throws {
        let url = apiURL("iap/subscriptions/resume/")
        let body = ResumeSubscriptionRequest(productId: productId, userId: userId)
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    /// Cancel a subscription.
    func cancelSubscription(productId: String, userId: String, immediate: Bool) async throws {
        let url = apiURL("iap/subscriptions/cancel/")
        let body = CancelSubscriptionRequest(productId: productId, userId: userId, immediate: immediate)
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - Upgrade Offer

    /// Fetch the upgrade offer configuration for a user/product.
    func fetchUpgradeOffer(userId: String, productId: String? = nil) async throws -> UpgradeOffer.Config {
        var components = URLComponents(url: apiURL("iap/upgrade-offer/"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "user_id", value: userId)]
        if let productId {
            queryItems.append(URLQueryItem(name: "product_id", value: productId))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct upgrade offer URL"))
        }

        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: UpgradeOffer.Config.self)
        }
    }

    /// Execute a subscription upgrade (web-to-web or storekit-to-web).
    func executeUpgradeOffer(_ request: UpgradeOffer.ExecuteRequest) async throws -> UpgradeOfferExecuteResponse {
        let url = apiURL("iap/upgrade-offer/execute/")
        return try await wrapped {
            try await httpClient.post(url, body: request, headers: authHeaders, responseType: UpgradeOfferExecuteResponse.self)
        }
    }

    /// Submit a declined/dismissed response for an upgrade offer.
    func respondUpgradeOffer(_ request: UpgradeOffer.RespondRequest) async throws {
        let url = apiURL("iap/upgrade-offer/respond/")
        try await wrapped { try await httpClient.postVoid(url, body: request, headers: authHeaders) }
    }

    // MARK: - StoreKit Subscription Status (Server-Side)

    /// Query the server for real-time Apple subscription status (bypasses on-device cache).
    func getStoreKitSubscriptionStatus(originalTransactionId: String) async throws -> StoreKitSubscriptionStatusResponse {
        var components = URLComponents(url: apiURL("iap/storekit-subscription-status/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "original_transaction_id", value: originalTransactionId)]

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct storekit-subscription-status URL"))
        }

        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: StoreKitSubscriptionStatusResponse.self)
        }
    }

    // MARK: - Funnel Analytics

    /// Send a funnel analytics event (fire-and-forget from the caller's perspective).
    func trackFunnelEvent(
        eventType: String,
        userId: String,
        productId: String,
        screenName: String?,
        metadata: [String: String]?
    ) async throws {
        let url = apiURL("iap/events/")
        let body = TrackFunnelEventRequest(
            eventType: eventType,
            userId: userId,
            productId: productId,
            screenName: screenName,
            metadata: metadata
        )
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - Error Wrapping

    /// Convert any error thrown by the HTTP layer into a typed ``ZeroSettleError/apiError(_:)``.
    /// If the error is already a ``ZeroSettleError``, it passes through unchanged.
    static func wrapError(_ error: Error) -> ZeroSettleError {
        if let iapError = error as? ZeroSettleError {
            return iapError
        }

        let detail = parseAPIErrorDetail(from: error)
        return .apiError(detail)
    }

    /// Parse an `HTTPError` (or any `Error`) into a structured `APIErrorDetail`.
    private static func parseAPIErrorDetail(from error: Error) -> APIErrorDetail {
        guard let httpError = error as? HTTPError else {
            return APIErrorDetail(
                statusCode: nil,
                serverMessage: nil,
                serverCode: nil,
                underlyingError: error
            )
        }

        switch httpError {
        case .httpError(let statusCode, let body):
            var serverMessage: String?
            var serverCode: String?

            if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                serverMessage = json["error"] as? String ?? json["message"] as? String ?? json["detail"] as? String
                serverCode = json["code"] as? String
            }

            return APIErrorDetail(
                statusCode: statusCode,
                serverMessage: serverMessage,
                serverCode: serverCode,
                underlyingError: error
            )

        case .networkError:
            return APIErrorDetail(
                statusCode: nil,
                serverMessage: nil,
                serverCode: nil,
                underlyingError: error
            )

        default:
            return APIErrorDetail(
                statusCode: nil,
                serverMessage: nil,
                serverCode: nil,
                underlyingError: error
            )
        }
    }

    // MARK: - Helpers

    /// Wraps an async operation with consistent error conversion to ``ZeroSettleError/apiError(_:)``.
    private func wrapped<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { throw Self.wrapError(error) }
    }

    private func apiURL(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }
}

// MARK: - Request/Response Models

private struct ProductsResponse: Decodable {
    let products: [ZSProduct]
    let config: ConfigResponse?
}

private struct ConfigResponse: Decodable {
    let checkout: CheckoutConfigResponse
    let migration: MigrationPromptResponse?
    let offer: Offer.OfferData?
}

private struct CheckoutConfigResponse: Decodable {
    let sheetType: String
    let isEnabled: Bool
    let jurisdictions: [String: JurisdictionConfigResponse]?
    let appleMerchantId: String?
}

private struct JurisdictionConfigResponse: Decodable {
    let sheetType: String
    let isEnabled: Bool
}

private struct MigrationPromptResponse: Decodable {
    let shouldShow: Bool
    let eligibleProductIds: [String]?
    let discountPercent: Int?
    let minSubscriptionDays: Int?
    let maxSubscriptionDays: Int?
    let freeTrialDays: Int?
    let title: String?
    let message: String?
    let ctaText: String?
    let rolloutPercent: Int?
    let perProductPrompts: [String: PerProductPromptResponse]?
}

private struct PerProductPromptResponse: Decodable {
    let discountPercent: Int
    let title: String
    let message: String
    let ctaText: String?
}

private struct EntitlementsResponse: Decodable {
    let entitlements: [Entitlement]
}

private struct TransactionHistoryResponse: Decodable {
    let transactions: [CheckoutTransaction]
}

internal struct CreateCheckoutSessionRequest: Encodable {
    let productId: String
    let userId: String?
    let externalUserId: String?
    let rcAppUserId: String?
    let platform: String = "ios"
    let customerName: String?
    let customerEmail: String?
}

internal struct InitiateCheckoutRequest: Encodable {
    let productId: String
    let userId: String?
    let stripeCustomerId: String?
    let storekitSubscriptionEnd: String?
    let storekitOriginalTransactionId: String?
    let checkoutMode: String?
    let platform: String = "ios"
    let customerName: String?
    let customerEmail: String?
    /// Apple external-purchase token (from `ExternalPurchase` disclosure sheet).
    /// Required for Apple auto-reporting — the backend gracefully handles nil.
    let externalPurchaseToken: String?
    /// Device iOS version (e.g. "26.4.1") — used by the backend regime detector
    /// to decide whether a transaction qualifies for Japan MSCA reporting.
    let iosVersion: String?
}

internal struct UpdateStorekitStatusRequest: Encodable {
    let storekitStatus: Int
    let storekitSubscriptionEnd: Date?
}

/// Response from the checkout initiation endpoint.
/// Contains the checkout URL and metadata for rendering the payment UI.
internal struct CheckoutResponse: Decodable {
    let clientSecret: String
    let transactionId: String
    let amount: Int
    let currency: String
    let productName: String
    let originalAmount: Int?
    let callbackUrl: String
    let publishableKey: String
    let checkoutUrl: String
    /// BYOS: connected account ID for PaymentIntent confirmation.
    let stripeAccount: String?
    /// ISO country code of the connected Stripe account (for Apple Pay).
    let merchantCountry: String?
    /// Whether this is a recurring (subscription) payment.
    let isSubscription: Bool?
    /// Billing interval for subscriptions: "week", "month", "year".
    let subscriptionInterval: String?
    /// Unix timestamp for trial end (migration free trials). When set, amount is 0 and payment is deferred.
    let trialEnd: Int?
    /// The amount (in cents) the customer will be charged when the trial ends.
    let pendingAmount: Int?
}

// MARK: - Batch Checkout

internal struct BatchCheckoutRequest: Encodable {
    struct ProductEntry: Encodable {
        let productId: String
        let storekitSubscriptionEnd: String?
        let storekitOriginalTransactionId: String?
    }
    let products: [ProductEntry]
    let userId: String?
    let stripeCustomerId: String?
    let platform: String = "ios"
    let customerName: String?
    let customerEmail: String?
}

internal struct BatchCheckoutResponse: Decodable {
    struct Result: Decodable {
        let productId: String
        let error: String?
        // All CheckoutResponse fields as optionals (absent when error is set)
        let clientSecret: String?
        let transactionId: String?
        let amount: Int?
        let currency: String?
        let productName: String?
        let originalAmount: Int?
        let callbackUrl: String?
        let publishableKey: String?
        let checkoutUrl: String?
        let stripeAccount: String?
        let merchantCountry: String?
        let isSubscription: Bool?
        let subscriptionInterval: String?
        let trialEnd: Int?
        let pendingAmount: Int?

        /// Convert a successful result to a full CheckoutResponse.
        func asCheckoutResponse() -> CheckoutResponse? {
            guard error == nil,
                  let clientSecret, let transactionId, let amount,
                  let currency, let productName, let callbackUrl,
                  let publishableKey, let checkoutUrl else { return nil }
            return CheckoutResponse(
                clientSecret: clientSecret,
                transactionId: transactionId,
                amount: amount,
                currency: currency,
                productName: productName,
                originalAmount: originalAmount,
                callbackUrl: callbackUrl,
                publishableKey: publishableKey,
                checkoutUrl: checkoutUrl,
                stripeAccount: stripeAccount,
                merchantCountry: merchantCountry,
                isSubscription: isSubscription,
                subscriptionInterval: subscriptionInterval,
                trialEnd: trialEnd,
                pendingAmount: pendingAmount
            )
        }
    }
    let results: [Result]
}

private struct SyncStoreKitTransactionRequest: Encodable {
    let jwsRepresentation: String
    let userId: String
}

internal struct SyncStoreKitTransactionResponse: Decodable {
    let status: String
    let owned: Bool?
    let originalTransactionId: String?

    enum CodingKeys: String, CodingKey {
        case status
        case owned
        case originalTransactionId = "original_transaction_id"
    }
}

internal struct ClaimEntitlementResponse: Decodable {
    let status: String
    let claimed: Bool?
    let productId: String?
    let originalTransactionId: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, claimed, message
        case productId = "product_id"
        case originalTransactionId = "original_transaction_id"
    }
}

private struct MigrationConversionRequest: Encodable {
    let userId: String
}

internal struct PauseSubscriptionRequest: Encodable {
    let productId: String
    let userId: String
    let pauseDurationDays: Int?
}

internal struct PauseSubscriptionResponse: Decodable {
    let resumesAt: Date?
}

internal struct ResumeSubscriptionRequest: Encodable {
    let productId: String
    let userId: String
}

internal struct CancelSubscriptionRequest: Encodable {
    let productId: String
    let userId: String
    let immediate: Bool
}

internal struct AcceptSaveOfferRequest: Encodable {
    let productId: String
    let userId: String
}

internal struct AcceptSaveOfferResponse: Decodable {
    let message: String
    let discountPercent: Int?
    let durationMonths: Int?
}

internal struct UpgradeOfferExecuteResponse: Decodable {
    let success: Bool
    let upgradeType: String?
    let checkoutUrl: String?
    let sessionId: String?
    let transactionId: String?
    let cancelInstructions: String?
}

internal struct TrackFunnelEventRequest: Encodable {
    let eventType: String
    let userId: String
    let productId: String
    let screenName: String?
    let metadata: [String: String]?
}

internal struct StoreKitSubscriptionStatusResponse: Decodable {
    /// 1 = active (subscribed + auto-renew on), 2 = cancelled/expired/other
    let status: Int
    /// 0 = auto-renew off, 1 = auto-renew on
    let autoRenewStatus: Int
    /// Subscription expiration date, if available
    let expiresAt: Date?
}
