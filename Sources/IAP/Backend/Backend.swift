//
//  Backend.swift
//  ZeroSettleIAP
//
//  Internal API client for ZeroSettle IAP endpoints.
//

import Foundation

#if canImport(ZeroSettleCore)
import ZeroSettleCore
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
    /// - Returns: Tuple of products and optional remote config
    func fetchProducts(userId: String? = nil) async throws -> (products: [Product], config: RemoteConfig?) {
        var components = URLComponents(url: apiURL("iap/products/"), resolvingAgainstBaseURL: false)!
        if let userId {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        }

        guard let url = components.url else {
            throw ZeroSettleIAPError.networkError(HTTPError.invalidURL("Failed to construct products URL"))
        }

        let response: ProductsResponse = try await httpClient.get(
            url,
            headers: authHeaders,
            responseType: ProductsResponse.self
        )

        // Parse remote config if present
        let remoteConfig: RemoteConfig?
        if let configResponse = response.config {
            let checkoutType = CheckoutType(rawValue: configResponse.checkout.sheetType) ?? .safari
            let checkoutConfig = CheckoutConfig(
                sheetType: checkoutType,
                isEnabled: configResponse.checkout.isEnabled
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

        return (response.products, remoteConfig)
    }

    // MARK: - Checkout Sessions

    /// Create a Stripe checkout session for the given product and user.
    /// The backend creates the session via the developer's connected Stripe Express account.
    func createCheckoutSession(productId: String, userId: String) async throws -> CheckoutSession {
        let url = apiURL("iap/checkout-sessions/")
        let body = CreateCheckoutSessionRequest(productId: productId, userId: userId)
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
    func createPaymentIntent(productId: String, userId: String) async throws -> PaymentIntentResponse {
        let url = apiURL("iap/payment-intents/")
        let body = CreatePaymentIntentRequest(productId: productId, userId: userId)
        return try await httpClient.post(
            url,
            body: body,
            headers: authHeaders,
            responseType: PaymentIntentResponse.self
        )
    }

    // MARK: - Transactions

    /// Get the status of a transaction by ID.
    func getTransaction(transactionId: String) async throws -> ZSTransaction {
        let url = apiURL("iap/transactions/\(transactionId)/")
        return try await httpClient.get(
            url,
            headers: authHeaders,
            responseType: ZSTransaction.self
        )
    }

    // MARK: - Entitlements

    /// Get the current entitlements for a user.
    func getEntitlements(userId: String) async throws -> [Entitlement] {
        var components = URLComponents(url: apiURL("iap/entitlements/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]

        guard let url = components.url else {
            throw ZeroSettleIAPError.networkError(HTTPError.invalidURL("Failed to construct entitlements URL"))
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

    // MARK: - Helpers

    private func apiURL(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }
}

// MARK: - Request/Response Models

private struct ProductsResponse: Decodable {
    let products: [Product]
    let config: ConfigResponse?
}

private struct ConfigResponse: Decodable {
    let checkout: CheckoutConfigResponse
    let migration: MigrationPromptResponse?
}

private struct CheckoutConfigResponse: Decodable {
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
    let userId: String
}

internal struct CreatePaymentIntentRequest: Encodable {
    let productId: String
    let userId: String
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
