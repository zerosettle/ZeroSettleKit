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
@MainActor
internal final class WebCheckoutFlow: NSObject {
    private let backend: Backend

    /// Continuation for inline checkout dismissal
    private var inlineCheckoutContinuation: CheckedContinuation<Void, Never>?

    /// Reference to the presented Safari view controller
    private var safariViewController: SFSafariViewController?

    /// The universal link hosts used for callbacks.
    ///
    /// ZeroSettle uses **universal links only** — no custom URL schemes.
    /// Universal links are verified via AASA, cannot be hijacked by other apps,
    /// and provide a seamless return-to-app experience.  The developer must add
    /// the Associated Domains entitlement for this to work:
    ///   `applinks:api.zerosettle.io?mode=developer` (dev)
    ///   `applinks:api.zerosettle.io` (production)
    private static let callbackHosts = CheckoutConstants.callbackHosts
    private static let callbackPathPrefix = CheckoutConstants.callbackPathPrefix

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
    func beginCheckout(
        productId: String,
        userId: String? = nil,
        presentation: CheckoutType? = nil
    ) async throws -> CheckoutSession {
        // Pre-flight: when the merchant is Apple-Pay-only, refuse to open the
        // browser if the device cannot complete the purchase. Mirrors the
        // bottom-sheet imperative gate. Honors .presentBuiltInUI by opening
        // system Wallet automatically before throwing. WebCheckoutFlow is
        // @MainActor-isolated at the class level, so ZeroSettle.shared and
        // applePayAvailability accessors are safe to call directly here.
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: ZeroSettle.shared.isApplePayOnly,
            state: ZeroSettle.shared.applePayAvailability.state,
            behavior: ZeroSettle.shared.resolvedApplePaySetupBehavior
        )
        if case .blocked(let error, let openSetupUI) = outcome {
            ZSLogger.info("[WebCheckoutFlow] beginCheckout blocked — error=\(error) openSetupUI=\(openSetupUI)", category: .checkout)
            if openSetupUI {
                ZeroSettle.shared.presentApplePaySetup()
            }
            throw error
        }

        ZSLogger.info("Creating checkout session for product: \(productId)", category: .checkout)

        // WebCheckoutFlow uses checkoutMode=browser which produces a different
        // checkout URL path than cached PIs (native mode). Always call the server.
        let response = try await backend.initiateCheckout(
            productId: productId,
            userId: userId,
            checkoutMode: .browser
        )

        guard let checkoutUrl = URL(string: response.checkoutUrl) else {
            throw ZeroSettleError.checkoutFailed(reason: .other("Invalid checkout URL"))
        }

        let session = CheckoutSession(
            sessionId: response.transactionId,
            checkoutUrl: checkoutUrl,
            transactionId: response.transactionId
        )

        ZSLogger.info("Checkout session created, transaction: \(session.transactionId ?? "none")", category: .checkout)

        // Per-call override (e.g. server-driven `Offer.checkoutPresentation`)
        // beats the global setting. Falls back to the global type when nil.
        let checkoutType = presentation ?? ZeroSettle.shared.checkoutType

        switch checkoutType {
        case .safari:
            ZSLogger.debug("Opening checkout URL in Safari", category: .checkout)
            await openInSafari(session.checkoutUrl)

        case .safariVC:
            ZSLogger.debug("Opening checkout URL in SFSafariViewController", category: .checkout)
            await openInSafariVC(session.checkoutUrl, transactionId: session.transactionId)

        case .webView, .nativePay:
            // WebView handled by CheckoutSheet, not WebCheckoutFlow.
            // nativePay falls through here when the NativePay trait isn't enabled
            // or Apple Pay is unavailable on the device.
            ZSLogger.debug("WebView checkout - session created but not opening browser", category: .checkout)
        }

        return session
    }

    // MARK: - Handle Callback

    /// Parse a universal link callback URL from the checkout flow.
    /// Automatically dismisses the inline checkout view if one is presented.
    /// - Parameter url: The universal link URL
    /// - Returns: Parsed callback data, or `nil` if the URL is not a ZeroSettle checkout callback
    func handleCallback(url: URL) -> CheckoutCallback? {
        ZSLogger.info("handleCallback: incoming URL: \(url.redactedForLogs)", category: .checkout)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parsedScheme = components?.scheme ?? "nil"
        let parsedHost = components?.host ?? "nil"
        let parsedPath = components?.path ?? "nil"
        ZSLogger.debug("handleCallback: parsed — scheme=\(parsedScheme), host=\(parsedHost), path=\(parsedPath)", category: .checkout)

        let hostMatched = components?.host.map { Self.callbackHosts.contains($0) } ?? false
        let pathMatched = components?.path.removingPercentEncoding?.hasPrefix(Self.callbackPathPrefix) ?? false
        ZSLogger.debug("handleCallback: hostMatched=\(hostMatched) (expected: \(Self.callbackHosts)), pathMatched=\(pathMatched) (expected prefix: \(Self.callbackPathPrefix))", category: .checkout)

        guard let components, hostMatched, pathMatched else {
            ZSLogger.debug("Universal link not handled by ZeroSettle: host=\(parsedHost), url=\(url). Expected hosts: \(Self.callbackHosts.joined(separator: ", ")) with path prefix \(Self.callbackPathPrefix)", category: .checkout)
            return nil
        }

        // Use uniquingKeysWith — `Dictionary(uniqueKeysWithValues:)` traps
        // when an upstream re-render accumulates duplicate sentinel params.
        let queryItems = components.queryItems ?? []
        let params = Dictionary(
            queryItems.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        ZSLogger.debug("handleCallback: query params: \(params)", category: .checkout)

        // Stripe Checkout (hosted) sets `status=success`/`status=cancelled` via
        // the success_url / cancel_url we hand to Stripe. The PaymentIntent flow
        // (browser-checkout.html) hands the redirect off to Stripe's confirmPayment,
        // which appends `redirect_status=succeeded`/`failed` instead. Accept both.
        guard let transactionId = params["transaction_id"],
              let productId = params["product_id"],
              let statusString = params["status"] ?? params["redirect_status"] else {
            ZSLogger.error("Checkout callback missing required parameters: \(url)", category: .checkout)
            return nil
        }

        let success = statusString == "success" || statusString == "succeeded"

        ZSLogger.info("Checkout callback received: transaction=\(transactionId), status=\(statusString)", category: .checkout)

        // Auto-dismiss inline checkout when callback is received
        if safariViewController != nil {
            ZSLogger.debug("Auto-dismissing inline checkout after callback", category: .checkout)
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
    func dismissSafariViewController() {
        presentedSafariVC?.dismiss(animated: true)
        presentedSafariVC = nil
    }

    // MARK: - Private

    /// Idempotent method to resume the inline checkout continuation exactly once.
    /// Safe to call from multiple dismissal paths — only the first call resumes;
    /// subsequent calls are no-ops because the continuation is nil-ed out.
    private func resumeCheckoutContinuation() {
        guard let continuation = inlineCheckoutContinuation else { return }
        inlineCheckoutContinuation = nil
        safariViewController = nil
        presentedSafariVC = nil
        continuation.resume()
    }

    /// Open a URL in the external Safari browser.
    /// Suspends until the user returns to the app (foreground notification).
    private func openInSafari(_ url: URL) async {
        ZSLogger.info("openInSafari: opening URL: \(url.redactedForLogs)", category: .checkout)

        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { _ in
                continuation.resume()
            }
        }

        let appState = UIApplication.shared.applicationState
        ZSLogger.debug("openInSafari: app state after open: \(appState == .active ? "active" : appState == .background ? "background" : "inactive")", category: .checkout)

        // External Safari backgrounds the app. Suspend until the user returns
        // so the caller can check whether the universal link callback fired.
        // Skip if the app didn't actually background (e.g., iPad split view).
        guard appState != .active else {
            ZSLogger.debug("openInSafari: app stayed active, not waiting for foreground", category: .checkout)
            return
        }

        ZSLogger.debug("openInSafari: waiting for willEnterForegroundNotification...", category: .checkout)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                ZSLogger.info("openInSafari: app returned to foreground", category: .checkout)
                continuation.resume()
            }
        }
    }

    /// Open a URL in an SFSafariViewController presented as a sheet.
    ///
    /// SFSafariViewController cannot intercept server-side redirects as universal links,
    /// so when a `transactionId` is provided we poll the transaction status in the background
    /// and auto-dismiss the sheet once the Stripe webhook confirms payment success.
    private func openInSafariVC(_ url: URL, transactionId: String? = nil) async {
        ZSLogger.info("openInSafariVC: opening URL: \(url.redactedForLogs)", category: .checkout)

        guard let topController = SafariPresentation.topViewController() else {
            ZSLogger.error("Unable to find root view controller for inline checkout", category: .checkout)
            // Fall back to external browser
            await openInSafari(url)
            return
        }
        ZSLogger.debug("openInSafariVC: presenting from: \(type(of: topController))", category: .checkout)

        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        safari.preferredControlTintColor = .systemGreen
        safari.dismissButtonStyle = .close
        safari.applyZSPageSheetPresentation()

        self.safariViewController = safari
        self.presentedSafariVC = safari

        // SFSafariViewController can't intercept redirect navigations as universal links.
        // Poll the transaction status in the background and auto-dismiss the sheet
        // once it reaches a terminal state (completion or failure).
        let pollTask: Task<Void, Never>?
        if let transactionId {
            ZSLogger.debug("openInSafariVC: starting transaction poll for \(transactionId)", category: .checkout)
            pollTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await CheckoutTransactionPoller.poll(
                    transactionId: transactionId,
                    backend: self.backend,
                    shouldContinue: { self.safariViewController != nil }
                )
                switch outcome {
                case .completed:
                    ZSLogger.info("Transaction \(transactionId) confirmed via polling, dismissing SFSafariViewController", category: .checkout)
                    self.dismissInlineCheckout()
                case .failed:
                    ZSLogger.info("Transaction \(transactionId) failed; dismissing SFSafariViewController", category: .checkout)
                    self.dismissInlineCheckout()
                case .exhausted:
                    ZSLogger.error("openInSafariVC: polling exhausted 20 attempts for \(transactionId) without confirmation", category: .checkout)
                case .terminalError(let error):
                    ZSLogger.error("openInSafariVC: terminal error polling \(transactionId): \(error.localizedDescription); dismissing SFSafariViewController", category: .checkout)
                    self.dismissInlineCheckout()
                }
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
    func dismissInlineCheckout() {
        safariViewController?.dismiss(animated: true) { [weak self] in
            self?.resumeCheckoutContinuation()
        }
    }
}

// MARK: - SFSafariViewControllerDelegate

extension WebCheckoutFlow: @preconcurrency SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        ZSLogger.debug("Inline checkout dismissed by user", category: .checkout)
        resumeCheckoutContinuation()
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
