//
//  WebCheckoutFlow.swift
//  ZeroSettleKit
//
//  Orchestrates the web checkout flow: session creation, Safari launch, and callback handling.
//

@preconcurrency import Foundation
import SafariServices
import UIKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
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
        ZSLogger.info("Creating checkout session for product: \(productId)", category: .iap)

        let session = try await backend.createCheckoutSession(
            productId: productId,
            userId: userId
        )

        ZSLogger.info("Checkout session created, transaction: \(session.transactionId ?? "none")", category: .iap)

        // Determine checkout type from remote config
        let checkoutType = ZeroSettle.shared.checkoutType

        switch checkoutType {
        case .safari:
            ZSLogger.debug("Opening checkout URL in Safari", category: .iap)
            await openInSafari(session.checkoutUrl)

        case .safariVC:
            ZSLogger.debug("Opening checkout URL in SFSafariViewController", category: .iap)
            await openInSafariVC(session.checkoutUrl, transactionId: session.transactionId)

        case .webView, .nativePay:
            // WebView handled by CheckoutSheet, not WebCheckoutFlow.
            // nativePay falls through here when the NativePay trait isn't enabled
            // or Apple Pay is unavailable on the device.
            ZSLogger.debug("WebView checkout - session created but not opening browser", category: .iap)
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
        ZSLogger.info("[handleCallback] incoming URL: \(url.absoluteString)", category: .iap)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parsedScheme = components?.scheme ?? "nil"
        let parsedHost = components?.host ?? "nil"
        let parsedPath = components?.path ?? "nil"
        ZSLogger.debug("[handleCallback] parsed — scheme=\(parsedScheme), host=\(parsedHost), path=\(parsedPath)", category: .iap)

        let hostMatched = components?.host.map { Self.callbackHosts.contains($0) } ?? false
        let pathMatched = components?.path.removingPercentEncoding?.hasPrefix(Self.callbackPathPrefix) ?? false
        ZSLogger.debug("[handleCallback] hostMatched=\(hostMatched) (expected: \(Self.callbackHosts)), pathMatched=\(pathMatched) (expected prefix: \(Self.callbackPathPrefix))", category: .iap)

        guard let components, hostMatched, pathMatched else {
            ZSLogger.debug("Universal link not handled by ZeroSettle: host=\(parsedHost), url=\(url). Expected hosts: \(Self.callbackHosts.joined(separator: ", ")) with path prefix \(Self.callbackPathPrefix)", category: .iap)
            return nil
        }

        let queryItems = components.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        ZSLogger.debug("[handleCallback] query params: \(params)", category: .iap)

        guard let transactionId = params["transaction_id"],
              let productId = params["product_id"],
              let statusString = params["status"] else {
            ZSLogger.error("Checkout callback missing required parameters: \(url)", category: .iap)
            return nil
        }

        let success = statusString == "success"

        ZSLogger.info("Checkout callback received: transaction=\(transactionId), status=\(statusString)", category: .iap)

        // Auto-dismiss inline checkout when callback is received
        if safariViewController != nil {
            ZSLogger.debug("Auto-dismissing inline checkout after callback", category: .iap)
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
    /// Suspends until the user returns to the app (foreground notification).
    @MainActor
    private func openInSafari(_ url: URL) async {
        ZSLogger.info("[openInSafari] opening URL: \(url.absoluteString)", category: .iap)

        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { _ in
                continuation.resume()
            }
        }

        let appState = UIApplication.shared.applicationState
        ZSLogger.debug("[openInSafari] app state after open: \(appState == .active ? "active" : appState == .background ? "background" : "inactive")", category: .iap)

        // External Safari backgrounds the app. Suspend until the user returns
        // so the caller can check whether the universal link callback fired.
        // Skip if the app didn't actually background (e.g., iPad split view).
        guard appState != .active else {
            ZSLogger.debug("[openInSafari] app stayed active, not waiting for foreground", category: .iap)
            return
        }

        ZSLogger.debug("[openInSafari] waiting for willEnterForegroundNotification...", category: .iap)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                ZSLogger.info("[openInSafari] app returned to foreground", category: .iap)
                continuation.resume()
            }
        }
    }

    /// Open a URL in an SFSafariViewController presented as a sheet.
    ///
    /// SFSafariViewController cannot intercept server-side redirects as universal links,
    /// so when a `transactionId` is provided we poll the transaction status in the background
    /// and auto-dismiss the sheet once the Stripe webhook confirms payment success.
    @MainActor
    private func openInSafariVC(_ url: URL, transactionId: String? = nil) async {
        ZSLogger.info("[openInSafariVC] opening URL: \(url.absoluteString)", category: .iap)

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            ZSLogger.error("Unable to find root view controller for inline checkout", category: .iap)
            // Fall back to external browser
            await openInSafari(url)
            return
        }

        // Find the topmost presented view controller
        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }
        ZSLogger.debug("[openInSafariVC] presenting from: \(type(of: topController))", category: .iap)

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

        // SFSafariViewController can't intercept redirect navigations as universal links.
        // Poll the transaction status in the background and auto-dismiss the sheet
        // once the Stripe webhook confirms the payment succeeded.
        let pollTask: Task<Void, Never>?
        if let transactionId {
            ZSLogger.debug("[openInSafariVC] starting transaction poll for \(transactionId)", category: .iap)
            pollTask = Task { [weak self] in
                // Give the user time to start the payment flow before polling
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for attempt in 1...20 {
                    guard !Task.isCancelled else { return }
                    let txn = try? await self?.backend.getTransaction(transactionId: transactionId)
                    ZSLogger.debug("[openInSafariVC] poll #\(attempt)/20 for \(transactionId): status=\(txn?.status.rawValue ?? "nil")", category: .iap)
                    if let txn, txn.status == .completed || txn.status == .processing {
                        ZSLogger.info("Transaction \(transactionId) confirmed via polling, dismissing SFSafariViewController", category: .iap)
                        self?.dismissInlineCheckout()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                ZSLogger.error("[openInSafariVC] polling exhausted 20 attempts for \(transactionId) without confirmation", category: .iap)
            }
        } else {
            pollTask = nil
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.inlineCheckoutContinuation = continuation
            topController.present(safari, animated: true)
        }

        pollTask?.cancel()
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
        ZSLogger.debug("Inline checkout dismissed by user", category: .iap)
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
