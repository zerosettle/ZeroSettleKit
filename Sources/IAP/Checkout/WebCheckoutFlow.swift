//
//  WebCheckoutFlow.swift
//  ZeroSettleIAP
//
//  Orchestrates the web checkout flow: session creation, Safari launch, and callback handling.
//

import Foundation
import UIKit
import ZeroSettleCore

// MARK: - Web Checkout Flow

/// Orchestrates the web checkout flow: creates a Stripe checkout session,
/// opens it in Safari, and parses the universal link callback.
internal final class WebCheckoutFlow {
    private let backend: Backend

    /// The universal link host used for callbacks.
#if DEBUG
    private static let callbackHost = "landing.zerosettle.ngrok.app"
#else
    private static let callbackHost = "zerosettle.io"
#endif
    private static let callbackPathPrefix = "/checkout/callback"

    init(backend: Backend) {
        self.backend = backend
    }

    // MARK: - Begin Checkout

    /// Create a checkout session and open it in Safari.
    /// - Parameters:
    ///   - productId: The product to purchase
    ///   - userId: The developer's user identifier
    /// - Returns: The checkout session (contains transactionId for status polling)
    @MainActor
    func beginCheckout(productId: String, userId: String) async throws -> CheckoutSession {
        Logger.info("Creating checkout session for product: \(productId)", category: .iap)

        let session = try await backend.createCheckoutSession(
            productId: productId,
            userId: userId
        )

        Logger.info("Checkout session created: \(session.sessionId)", category: .iap)
        Logger.debug("Opening checkout URL in Safari", category: .iap)

        await openInBrowser(session.checkoutUrl)

        return session
    }

    // MARK: - Handle Callback

    /// Parse a universal link callback URL from the checkout flow.
    /// - Parameter url: The universal link URL
    /// - Returns: Parsed callback data, or `nil` if the URL is not a ZeroSettle checkout callback
    func handleCallback(url: URL) -> CheckoutCallback? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == Self.callbackHost,
              let path = components.path.removingPercentEncoding,
              path.hasPrefix(Self.callbackPathPrefix) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let transactionId = params["transaction_id"],
              let productId = params["product_id"],
              let statusString = params["status"] else {
            Logger.error("Checkout callback missing required parameters: \(url)", category: .iap)
            return nil
        }

        let success = statusString == "success"

        Logger.info("Checkout callback received: transaction=\(transactionId), status=\(statusString)", category: .iap)

        return CheckoutCallback(
            transactionId: transactionId,
            productId: productId,
            success: success
        )
    }

    // MARK: - Private

    /// Open a URL in the system browser (Safari).
    @MainActor
    private func openInBrowser(_ url: URL) async {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { _ in
                continuation.resume()
            }
        }
    }
}

// MARK: - Checkout Session

/// Represents a checkout session created by the ZeroSettle backend.
internal struct CheckoutSession: Codable, Sendable {
    /// Backend-assigned session identifier
    let sessionId: String

    /// The Stripe checkout URL to open in Safari
    let checkoutUrl: URL

    /// Pre-allocated transaction ID for status polling
    let transactionId: String
}

// MARK: - Checkout Callback

/// Parsed data from a universal link checkout callback.
internal struct CheckoutCallback: Sendable {
    /// The transaction ID from the checkout
    let transactionId: String

    /// The product that was purchased
    let productId: String

    /// Whether the checkout completed successfully
    let success: Bool
}
