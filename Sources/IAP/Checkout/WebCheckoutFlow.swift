//
//  WebCheckoutFlow.swift
//  ZeroSettleIAP
//
//  Orchestrates the web checkout flow: session creation, Safari launch, and callback handling.
//

import Foundation
import SafariServices
import UIKit

#if !COCOAPODS
import ZeroSettleCore
#endif

// MARK: - Checkout UX Mode

/// Defines how the checkout web view is presented to the user.
internal enum CheckoutUX {
    /// Opens checkout in an inline web view popover (SFSafariViewController)
    case inline
    /// Opens checkout in external Safari browser
    case externalBrowser
}

// MARK: - Web Checkout Flow

/// Orchestrates the web checkout flow: creates a Stripe checkout session,
/// opens it in Safari, and parses the universal link callback.
internal final class WebCheckoutFlow: NSObject {
    private let backend: Backend
    
    /// Controls how the checkout UI is presented. Change this to switch between inline and external browser.
    private static let checkoutUX: CheckoutUX = .inline
    
    /// Continuation for inline checkout dismissal
    private var inlineCheckoutContinuation: CheckedContinuation<Void, Never>?
    
    /// Reference to the presented Safari view controller
    private var safariViewController: SFSafariViewController?

    /// The universal link hosts used for callbacks (accept both prod and dev).
    private static let callbackHosts = ["api.zerosettle.io", "landing.zerosettle.ngrok.app"]
    private static let callbackPathPrefix = "/checkout/callback"

    init(backend: Backend) {
        self.backend = backend
        super.init()
    }

    // MARK: - Begin Checkout

    /// Create a checkout session and open it based on the configured UX mode.
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
        
        switch Self.checkoutUX {
        case .inline:
            Logger.debug("Opening checkout URL in inline web view", category: .iap)
            await openInlineWebView(session.checkoutUrl)
        case .externalBrowser:
            Logger.debug("Opening checkout URL in Safari", category: .iap)
            await openInBrowser(session.checkoutUrl)
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
    
    /// Open a URL in an inline web view popover using SFSafariViewController.
    @MainActor
    private func openInlineWebView(_ url: URL) async {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            Logger.error("Unable to find root view controller for inline checkout", category: .iap)
            // Fall back to external browser
            await openInBrowser(url)
            return
        }
        
        // Find the topmost presented view controller
        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }
        
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        safari.preferredControlTintColor = .systemBlue
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
