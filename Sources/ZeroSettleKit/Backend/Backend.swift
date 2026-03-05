//
//  Backend.swift
//  ZeroSettleKit
//
//  Internal API client for ZeroSettle IAP endpoints.
//

import Foundation

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
            // Log raw migration response for debugging
            if let migrationRaw = configResponse.migration {
                ZSLogger.info("Raw migration response from server: shouldShow=\(migrationRaw.shouldShow), eligibleProductIds=\(migrationRaw.eligibleProductIds as Any), discountPercent=\(migrationRaw.discountPercent as Any), title=\(migrationRaw.title as Any), message=\(migrationRaw.message as Any)", category: .network)
            } else {
                ZSLogger.info("Server returned nil migration config", category: .network)
            }
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

            // Log jurisdiction overrides for developer visibility
            if !jurisdictions.isEmpty {
                let overrideSummary = jurisdictions.map { "\($0.key.rawValue)=\($0.value.sheetType.rawValue)(enabled:\($0.value.isEnabled))" }.joined(separator: ", ")
                ZSLogger.info("Jurisdiction overrides: \(overrideSummary)", category: .network)
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
                ZSLogger.info("Migration response received: shouldShow=\(migrationResponse.shouldShow), eligibleProductIds=\(eligible), discountPercent=\(migrationResponse.discountPercent.map(String.init) ?? "nil"), title=\(migrationResponse.title ?? "nil"), message=\(migrationResponse.message ?? "nil")", category: .network)

                if migrationResponse.shouldShow,
                   let discountPercent = migrationResponse.discountPercent,
                   let title = migrationResponse.title,
                   let message = migrationResponse.message {
                    // Pass through the backend discount as-is. When it's 0, the
                    // MigrationManager will resolve the real savings from the
                    // matched product's web vs StoreKit price and re-interpolate.
                    migration = MigrationPrompt(
                        productId: eligible.first ?? "",
                        eligibleProductIds: eligible,
                        discountPercent: discountPercent,
                        title: title,
                        message: message,
                        ctaText: migrationResponse.ctaText ?? (discountPercent > 0 ? "Save \(discountPercent)% Forever" : "Switch Now")
                    )
                    ZSLogger.info("Migration prompt created: eligibleProductIds=\(eligible), discountPercent=\(discountPercent), title=\(title)", category: .network)
                } else {
                    migration = nil
                    ZSLogger.info("Migration prompt nil: shouldShow=\(migrationResponse.shouldShow), missing fields: discountPercent=\(migrationResponse.discountPercent == nil), title=\(migrationResponse.title == nil), message=\(migrationResponse.message == nil)", category: .network)
                }
            } else {
                migration = nil
                ZSLogger.info("No migration object in config response", category: .network)
            }

            remoteConfig = RemoteConfig(checkout: checkoutConfig, migration: migration)
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
        let body = CreateCheckoutSessionRequest(
            productId: productId,
            userId: userId,
            externalUserId: externalUserId,
            rcAppUserId: rcAppUserId
        )
        return try await httpClient.post(
            url,
            body: body,
            headers: authHeaders,
            responseType: CheckoutSession.self
        )
    }

    // MARK: - Payment Intents (for native checkout)

    /// Create a Stripe PaymentIntent for native checkout (Apple Pay / Card in WebView).
    /// Returns data needed for the Payment Request API and card entry form.
    func createPaymentIntent(productId: String, userId: String? = nil, freeTrialDays: Int, stripeCustomerId: String? = nil) async throws -> PaymentIntentResponse {
        let url = apiURL("iap/payment-intents/")
        let body = CreatePaymentIntentRequest(productId: productId, userId: userId, freeTrialDays: freeTrialDays, stripeCustomerId: stripeCustomerId)
        do {
            return try await httpClient.post(
                url,
                body: body,
                headers: authHeaders,
                responseType: PaymentIntentResponse.self
            )
        } catch {
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Transactions

    /// Get the status of a transaction by ID.
    func getTransaction(transactionId: String) async throws -> CheckoutTransaction {
        let url = apiURL("iap/transactions/\(transactionId)/")
        do {
            return try await httpClient.get(
                url,
                headers: authHeaders,
                responseType: CheckoutTransaction.self
            )
        } catch {
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Transaction Verification

    /// Poll the backend to verify a transaction has completed.
    /// Used by both `CheckoutSheet` (webview path) and `ZeroSettle.purchase()` (safari paths).
    ///
    /// Waits an initial 1.5s for webhook processing, then polls `getTransaction()`
    /// up to `maxAttempts` times. Returns the transaction on `.completed` or
    /// `.processing` (final attempt), throws `PaymentSheetError.cancelled` on
    /// pending/failed, and `PaymentSheetError.verificationFailed` on timeout.
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
                throw PaymentSheetError.cancelled
            default:
                // .failed, .refunded — terminal error states
                throw PaymentSheetError.cancelled
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

        let response: EntitlementsResponse = try await httpClient.get(
            url,
            headers: authHeaders,
            responseType: EntitlementsResponse.self
        )
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

        let response: TransactionHistoryResponse = try await httpClient.get(
            url,
            headers: authHeaders,
            responseType: TransactionHistoryResponse.self
        )
        return response.transactions
    }

    // MARK: - Migration Tracking

    /// Track a successful migration conversion (user switched from StoreKit to web checkout).
    func trackMigrationConversion(userId: String) async throws {
        let url = apiURL("iap/migration-converted/")
        let body = MigrationConversionRequest(userId: userId)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try encoder.encode(body)

        try await httpClient.executeVoid(request)
    }

    // MARK: - StoreKit Transaction Sync

    /// Forward a StoreKit transaction's JWS representation for server-side verification.
    func syncStoreKitTransaction(jwsRepresentation: String, userId: String) async throws {
        let url = apiURL("iap/storekit-transactions/")
        let body = SyncStoreKitTransactionRequest(
            jwsRepresentation: jwsRepresentation,
            userId: userId
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try encoder.encode(body)

        try await httpClient.executeVoid(request)
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

        return try await httpClient.get(
            url,
            headers: authHeaders,
            responseType: CancelFlow.Config.self
        )
    }

    /// Submit a cancel flow response (fire-and-forget from the caller's perspective).
    func submitCancelFlowResponse(_ payload: CancelFlow.ResponsePayload) async throws {
        let url = apiURL("iap/cancel-flow/respond/")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try encoder.encode(payload)

        try await httpClient.executeVoid(request)
    }

    /// Accept the save offer for a cancel flow, applying the discount on Stripe.
    func acceptSaveOffer(productId: String, userId: String) async throws -> AcceptSaveOfferResponse {
        let url = apiURL("iap/cancel-flow/accept-offer/")
        let body = AcceptSaveOfferRequest(productId: productId, userId: userId)
        do {
            return try await httpClient.post(
                url,
                body: body,
                headers: authHeaders,
                responseType: AcceptSaveOfferResponse.self
            )
        } catch {
            throw Backend.wrapError(error)
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
        do {
            return try await httpClient.post(
                url,
                body: body,
                headers: authHeaders,
                responseType: PauseSubscriptionResponse.self
            )
        } catch {
            throw Backend.wrapError(error)
        }
    }

    /// Resume a paused subscription.
    /// - Parameters:
    ///   - productId: The product to resume
    ///   - userId: The user who owns the subscription
    func resumeSubscription(productId: String, userId: String) async throws {
        let url = apiURL("iap/subscriptions/resume/")
        let body = ResumeSubscriptionRequest(productId: productId, userId: userId)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try encoder.encode(body)

        try await httpClient.executeVoid(request)
    }

    /// Cancel a subscription.
    /// - Parameters:
    ///   - productId: The product to cancel
    ///   - userId: The user who owns the subscription
    ///   - immediate: If `true`, cancel immediately. If `false`, cancel at period end.
    func cancelSubscription(productId: String, userId: String, immediate: Bool) async throws {
        let url = apiURL("iap/subscriptions/cancel/")
        let body = CancelSubscriptionRequest(productId: productId, userId: userId, immediate: immediate)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try encoder.encode(body)

        try await httpClient.executeVoid(request)
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

        return try await httpClient.get(
            url,
            headers: authHeaders,
            responseType: UpgradeOffer.Config.self
        )
    }

    /// Execute a subscription upgrade (web-to-web or storekit-to-web).
    func executeUpgradeOffer(_ request: UpgradeOffer.ExecuteRequest) async throws -> UpgradeOfferExecuteResponse {
        let url = apiURL("iap/upgrade-offer/execute/")
        do {
            return try await httpClient.post(
                url,
                body: request,
                headers: authHeaders,
                responseType: UpgradeOfferExecuteResponse.self
            )
        } catch {
            throw Backend.wrapError(error)
        }
    }

    /// Submit a declined/dismissed response for an upgrade offer.
    func respondUpgradeOffer(_ request: UpgradeOffer.RespondRequest) async throws {
        let url = apiURL("iap/upgrade-offer/respond/")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeaders.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        urlRequest.httpBody = try encoder.encode(request)

        try await httpClient.executeVoid(urlRequest)
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try encoder.encode(body)

        try await httpClient.executeVoid(request)
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
    let title: String?
    let message: String?
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
}

internal struct CreatePaymentIntentRequest: Encodable {
    let productId: String
    let userId: String?
    let freeTrialDays: Int
    let stripeCustomerId: String?
    let platform: String = "ios"
}

/// Response from the create_payment_intent endpoint.
/// Contains everything needed to render the native checkout WebView or native Apple Pay sheet.
internal struct PaymentIntentResponse: Decodable {
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
    /// Whether this is a recurring (subscription) payment.
    let isSubscription: Bool?
    /// Billing interval for subscriptions: "week", "month", "year".
    let subscriptionInterval: String?
}

private struct SyncStoreKitTransactionRequest: Encodable {
    let jwsRepresentation: String
    let userId: String
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
