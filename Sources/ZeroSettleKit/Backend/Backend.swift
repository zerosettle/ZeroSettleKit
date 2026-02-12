//
//  Backend.swift
//  ZeroSettleKit
//
//  Internal API client for ZeroSettle IAP endpoints.
//

import Foundation

#if canImport(ZeroSettleCore)
@_implementationOnly import ZeroSettleCore
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
        let span = PaymentSheetTrace.current?.begin("fetchProducts", metadata: ["userId": userId ?? "(none)"])

        var components = URLComponents(url: apiURL("iap/products/"), resolvingAgainstBaseURL: false)!
        if let userId {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        }

        guard let url = components.url else {
            if let span { PaymentSheetTrace.current?.end(span, metadata: ["error": "invalidURL"]) }
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct products URL"))
        }

        let netSpan = PaymentSheetTrace.current?.begin("GET /iap/products")
        let response: ProductsResponse
        do {
            response = try await httpClient.get(
                url,
                headers: authHeaders,
                responseType: ProductsResponse.self
            )
            if let netSpan { PaymentSheetTrace.current?.end(netSpan, metadata: ["products": "\(response.products.count)"]) }
        } catch {
            if let netSpan { PaymentSheetTrace.current?.end(netSpan, metadata: ["error": "\(error)"]) }
            if let span { PaymentSheetTrace.current?.end(span, metadata: ["error": "\(error)"]) }
            throw Backend.wrapError(error)
        }

        // Parse remote config if present
        let remoteConfig: RemoteConfig?
        if let configResponse = response.config {
            let checkoutType = CheckoutType(rawValue: configResponse.checkout.sheetType) ?? .safari

            // Parse jurisdiction overrides
            var jurisdictions: [Jurisdiction: JurisdictionCheckoutConfig] = [:]
            if let jurDict = configResponse.checkout.jurisdictions {
                for (key, value) in jurDict {
                    guard let jurisdiction = Jurisdiction(rawValue: key),
                          let sheetType = CheckoutType(rawValue: value.sheetType) else { continue }
                    jurisdictions[jurisdiction] = JurisdictionCheckoutConfig(
                        sheetType: sheetType,
                        isEnabled: value.isEnabled
                    )
                }
            }

            let checkoutConfig = CheckoutConfig(
                sheetType: checkoutType,
                isEnabled: configResponse.checkout.isEnabled,
                jurisdictions: jurisdictions
            )

            let migration: MigrationPrompt?
            if let migrationResponse = configResponse.migration,
               migrationResponse.shouldShow,
               let productId = migrationResponse.productId,
               let discountPercent = migrationResponse.discountPercent,
               let title = migrationResponse.title,
               let message = migrationResponse.message {
                migration = MigrationPrompt(
                    productId: productId,
                    discountPercent: discountPercent,
                    title: title,
                    message: message
                )
            } else {
                migration = nil
            }

            remoteConfig = RemoteConfig(checkout: checkoutConfig, migration: migration)
        } else {
            remoteConfig = nil
        }

        if let span { PaymentSheetTrace.current?.end(span, metadata: ["products": "\(response.products.count)"]) }
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
    func createPaymentIntent(productId: String, userId: String? = nil, freeTrialDays: Int) async throws -> PaymentIntentResponse {
        let span = PaymentSheetTrace.current?.begin("POST /iap/payment-intents", metadata: ["productId": productId])
        do {
            let url = apiURL("iap/payment-intents/")
            let body = CreatePaymentIntentRequest(productId: productId, userId: userId, freeTrialDays: freeTrialDays)
            let response = try await httpClient.post(
                url,
                body: body,
                headers: authHeaders,
                responseType: PaymentIntentResponse.self
            )
            if let span { PaymentSheetTrace.current?.end(span, metadata: ["txnId": response.transactionId]) }
            return response
        } catch {
            if let span { PaymentSheetTrace.current?.end(span, metadata: ["error": "\(error)"]) }
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Transactions

    /// Get the status of a transaction by ID.
    func getTransaction(transactionId: String) async throws -> ZSTransaction {
        let span = PaymentSheetTrace.current?.begin("GET /iap/transactions", metadata: ["txnId": transactionId])
        do {
            let url = apiURL("iap/transactions/\(transactionId)/")
            let response = try await httpClient.get(
                url,
                headers: authHeaders,
                responseType: ZSTransaction.self
            )
            if let span { PaymentSheetTrace.current?.end(span, metadata: ["status": response.status.rawValue]) }
            return response
        } catch {
            if let span { PaymentSheetTrace.current?.end(span, metadata: ["error": "\(error)"]) }
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Transaction Verification

    /// Poll the backend to verify a transaction has completed.
    /// Used by both `ZSPaymentSheet` (webview path) and `ZeroSettle.purchase()` (safari paths).
    ///
    /// Waits an initial 1.5s for webhook processing, then polls `getTransaction()`
    /// up to `maxAttempts` times. Returns the transaction on `.completed` or
    /// `.processing` (final attempt), throws `PaymentSheetError.cancelled` on
    /// pending/failed, and `PaymentSheetError.verificationFailed` on timeout.
    func verifyTransaction(
        transactionId: String,
        maxAttempts: Int = 6,
        pollInterval: UInt64 = 2_000_000_000
    ) async throws -> ZSTransaction {
        // Initial delay for webhook processing
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var lastTransaction: ZSTransaction?
        for attempt in 1...maxAttempts {
            let transaction = try await getTransaction(transactionId: transactionId)
            lastTransaction = transaction

            switch transaction.status {
            case .completed:
                return transaction
            case .processing:
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    continue
                }
                // Final attempt still processing — treat as completed
                return transaction
            default:
                // pending/failed — user didn't complete payment
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

    // MARK: - Customer Portal

    /// Create a Stripe customer portal session for subscription management.
    func createCustomerPortalSession(userId: String) async throws -> CustomerPortalSession {
        let url = apiURL("iap/customer-portal-sessions/")
        let body = CreateCustomerPortalSessionRequest(userId: userId)
        do {
            return try await httpClient.post(
                url,
                body: body,
                headers: authHeaders,
                responseType: CustomerPortalSession.self
            )
        } catch {
            throw Backend.wrapError(error)
        }
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

    // MARK: - Error Wrapping

    /// Convert any error thrown by the HTTP layer into a typed ``ZSError/apiError(_:)``.
    /// If the error is already a ``ZSError``, it passes through unchanged.
    static func wrapError(_ error: Error) -> ZSError {
        if let iapError = error as? ZSError {
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
}

private struct JurisdictionConfigResponse: Decodable {
    let sheetType: String
    let isEnabled: Bool
}

private struct MigrationPromptResponse: Decodable {
    let shouldShow: Bool
    let productId: String?
    let discountPercent: Int?
    let title: String?
    let message: String?
}

private struct EntitlementsResponse: Decodable {
    let entitlements: [Entitlement]
}

internal struct CreateCheckoutSessionRequest: Encodable {
    let productId: String
    let userId: String?
    let externalUserId: String?
    let rcAppUserId: String?
}

internal struct CreatePaymentIntentRequest: Encodable {
    let productId: String
    let userId: String?
    let freeTrialDays: Int
}

/// Response from the create_payment_intent endpoint.
/// Contains everything needed to render the native checkout WebView.
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
}

private struct SyncStoreKitTransactionRequest: Encodable {
    let jwsRepresentation: String
    let userId: String
}

private struct MigrationConversionRequest: Encodable {
    let userId: String
}

internal struct CreateCustomerPortalSessionRequest: Encodable {
    let userId: String
}

internal struct CustomerPortalSession: Decodable {
    let portalUrl: URL
}
