//
//  WebCheckoutFlow.swift
//  ZeroSettleKit
//
//  Orchestrates the web checkout flow: session creation, Safari launch, and callback handling.
//

import Foundation
import SafariServices
import UIKit

#if canImport(ZeroSettleCore)
@_implementationOnly import ZeroSettleCore
#endif

// MARK: - Web Checkout Flow

/// Orchestrates the web checkout flow: creates a Stripe checkout session,
/// opens it in Safari or SFSafariViewController, and parses the universal link callback.
internal final class WebCheckoutFlow: NSObject {
    private let backend: Backend

    /// Continuation for inline checkout dismissal
    private var inlineCheckoutContinuation: CheckedContinuation<Void, Never>?

    /// Reference to the presented Safari view controller
    private var safariViewController: SFSafariViewController?

    /// The universal link hosts used for callbacks (accept both prod and dev).
    private static let callbackHosts = ["api.zerosettle.io", "landing.zerosettle.ngrok.app"]
    private static let callbackPathPrefix = "/checkout/callback"

    /// Currently presented SFSafariViewController (if any).
    private weak var presentedSafariVC: SFSafariViewController?

    init(backend: Backend) {
        self.backend = backend
        super.init()
    }

    // MARK: - Begin Checkout

    /// Create a checkout session and open it in the appropriate browser.
    /// Respects the configured checkout type from `ZeroSettle.shared.checkoutType`.
    ///
    /// - Parameters:
    ///   - productId: The product to purchase
    ///   - userId: The developer's user identifier
    /// - Returns: The checkout session (contains transactionId for status polling)
    @MainActor
    func beginCheckout(productId: String, userId: String? = nil) async throws -> CheckoutSession {
        Logger.info("Creating payment intent for product: \(productId)", category: .iap)

        let response = try await backend.createPaymentIntent(
            productId: productId,
            userId: userId
        )

        guard let checkoutUrl = URL(string: response.checkoutUrl) else {
            throw ZSError.apiError(APIErrorDetail(
                statusCode: nil,
                serverMessage: "Invalid checkout URL returned by server",
                serverCode: nil,
                underlyingError: nil
            ))
        }

        let session = CheckoutSession(
            sessionId: response.transactionId,
            checkoutUrl: checkoutUrl,
            transactionId: response.transactionId
        )

        Logger.info("Payment intent created, transaction: \(response.transactionId)", category: .iap)

        // Determine checkout type from remote config
        let checkoutType = ZeroSettle.shared.checkoutType

        switch checkoutType {
        case .safari:
            Logger.debug("Opening checkout URL in Safari", category: .iap)
            await openInSafari(session.checkoutUrl)

        case .safariVC:
            Logger.debug("Opening checkout URL in SFSafariViewController", category: .iap)
            await openInSafariVC(session.checkoutUrl)

        case .webview:
            // WebView handled by ZSPaymentSheet, not WebCheckoutFlow
            Logger.debug("WebView checkout - session created but not opening browser", category: .iap)
        }

        return session
    }

    // MARK: - Handle Callback

    /// Parse a universal link callback URL from the checkout flow.
    /// Automatically dismisses the inline checkout view if one is presented.
    /// - Parameter url: The universal link URL
    /// - Returns: Parsed callback data, or `nil` if the URL is not a ZeroSettle checkout callback
    @MainActor
    func handleCallback(url: URL) -> CheckoutCallback? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              Self.callbackHosts.contains(host),
              let path = components.path.removingPercentEncoding,
              path.hasPrefix(Self.callbackPathPrefix) else {
            Logger.error("Unable to handle callback due to invalid components: \(url)")
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

        // Auto-dismiss inline checkout when callback is received
        if safariViewController != nil {
            Logger.debug("Auto-dismissing inline checkout after callback", category: .iap)
            dismissInlineCheckout()
        }

        return CheckoutCallback(
            transactionId: transactionId,
            productId: productId,
            success: success
        )
    }

    // MARK: - Safari VC Dismissal

    /// Dismiss the currently presented SFSafariViewController (if any).
    /// Call this after handling a universal link callback to close the in-app browser.
    @MainActor
    func dismissSafariViewController() {
        presentedSafariVC?.dismiss(animated: true)
        presentedSafariVC = nil
    }

    // MARK: - Private

    /// Open a URL in the external Safari browser.
    @MainActor
    private func openInSafari(_ url: URL) async {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { _ in
                continuation.resume()
            }
        }
    }

    /// Open a URL in an SFSafariViewController presented as a sheet.
    @MainActor
    private func openInSafariVC(_ url: URL) async {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            Logger.error("Unable to find root view controller for inline checkout", category: .iap)
            // Fall back to external browser
            await openInSafari(url)
            return
        }

        // Find the topmost presented view controller
        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }

        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        safari.preferredControlTintColor = .systemGreen
        safari.dismissButtonStyle = .close

        // Present as a sheet on iOS 15+
        if #available(iOS 15.0, *) {
            safari.modalPresentationStyle = .pageSheet
            if let sheet = safari.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
        } else {
            safari.modalPresentationStyle = .formSheet
        }

        self.safariViewController = safari
        self.presentedSafariVC = safari

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.inlineCheckoutContinuation = continuation
            topController.present(safari, animated: true)
        }
    }

    /// Dismiss the inline checkout view if it's currently presented.
    @MainActor
    func dismissInlineCheckout() {
        safariViewController?.dismiss(animated: true) { [weak self] in
            self?.safariViewController = nil
            self?.presentedSafariVC = nil
            self?.inlineCheckoutContinuation?.resume()
            self?.inlineCheckoutContinuation = nil
        }
    }
}

// MARK: - SFSafariViewControllerDelegate

extension WebCheckoutFlow: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Logger.debug("Inline checkout dismissed by user", category: .iap)
        safariViewController = nil
        presentedSafariVC = nil
        inlineCheckoutContinuation?.resume()
        inlineCheckoutContinuation = nil
    }
}

// MARK: - Checkout Session

/// Represents a checkout session created by the ZeroSettle backend.
internal struct CheckoutSession: Codable, Sendable {
    /// Backend-assigned session identifier
    let sessionId: String

    /// The Stripe checkout URL to open in Safari
    let checkoutUrl: URL

    /// Pre-allocated transaction ID for status polling (optional for backwards compatibility)
    let transactionId: String?
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
