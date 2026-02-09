//
//  ZeroSettleCheckoutView.swift
//  ZeroSettleIAP
//
//  Embedded checkout view using WKWebView for native WebView mode.
//

import Foundation
import SwiftUI
import WebKit

// MARK: - ZeroSettleCheckoutView

/// An embedded checkout view for native WebView mode.
///
/// - Important: This view is deprecated. Use `ZSPaymentSheet` instead, which provides
///   a better user experience with preloading, Apple Pay support, and proper presentation.
///
/// Use this view when `ZeroSettleIAP.shared.checkoutType == .webview`.
/// The developer controls placement and sizing of this view.
///
/// Example usage:
/// ```swift
/// // Deprecated - use ZSPaymentSheet instead:
/// // .zsPaymentSheet(isPresented: $showPayment, product: product, userId: userId) { result in ... }
///
/// ZeroSettleCheckoutView(
///     productId: "premium_monthly",
///     userId: currentUser.id
/// ) { result in
///     switch result {
///     case .success(let transaction):
///         print("Purchase completed: \(transaction.id)")
///     case .failure(let error):
///         print("Purchase failed: \(error)")
///     }
/// }
/// .frame(maxWidth: 400)
/// .cornerRadius(16)
/// ```
@available(*, deprecated, message: "Use ZSPaymentSheet instead, which provides preloading and better UX")
public struct ZeroSettleCheckoutView: View {
    private let productId: String
    private let userId: String
    private let onComplete: (Result<ZSTransaction, Error>) -> Void

    @StateObject private var viewModel = CheckoutViewModel()

    /// Create a new checkout view.
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: Your app's user identifier
    ///   - onComplete: Called when checkout completes, fails, or is cancelled
    public init(
        productId: String,
        userId: String,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        self.productId = productId
        self.userId = userId
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            if let checkoutURL = viewModel.checkoutURL {
                CheckoutSessionWebView(
                    url: checkoutURL,
                    onComplete: { result in
                        Task { @MainActor in
                            await handleWebViewResult(result)
                        }
                    }
                )
            } else if let error = viewModel.error {
                errorView(error)
            } else {
                loadingView
            }
        }
        .task {
            await viewModel.createCheckoutSession(productId: productId, userId: userId)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading checkout...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Unable to load checkout")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task {
                    await viewModel.createCheckoutSession(productId: productId, userId: userId)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func handleWebViewResult(_ result: WebViewCheckoutResult) async {
        switch result {
        case .success(let transactionId):
            // Verify the transaction with the backend
            do {
                let transaction = try await viewModel.verifyTransaction(transactionId: transactionId)
                onComplete(.success(transaction))
            } catch {
                onComplete(.failure(error))
            }

        case .cancelled:
            onComplete(.failure(CheckoutError.cancelled))

        case .failure(let error):
            onComplete(.failure(error))
        }
    }
}

// MARK: - Checkout Error

/// Errors that can occur during embedded checkout.
@available(*, deprecated, message: "Use ZSPaymentSheet and PaymentSheetError instead")
public enum CheckoutError: Error, LocalizedError {
    case cancelled
    case sessionCreationFailed(String)
    case transactionVerificationFailed(String)
    case webViewError(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Checkout was cancelled"
        case .sessionCreationFailed(let message):
            return "Failed to create checkout session: \(message)"
        case .transactionVerificationFailed(let message):
            return "Transaction verification failed: \(message)"
        case .webViewError(let message):
            return "WebView error: \(message)"
        }
    }
}

// MARK: - WebView Checkout Result

enum WebViewCheckoutResult {
    case success(transactionId: String)
    case cancelled
    case failure(Error)
}

// MARK: - Checkout View Model

@MainActor
private final class CheckoutViewModel: ObservableObject {
    @Published var checkoutURL: URL?
    @Published var error: Error?
    @Published var transactionId: String?

    private var backend: Backend? {
        // Access the backend from ZeroSettleIAP
        // This is a bit of a workaround since Backend is internal
        nil // Will be set via the checkout session response
    }

    func createCheckoutSession(productId: String, userId: String) async {
        error = nil
        checkoutURL = nil

        // Access ZeroSettleIAP's internal checkoutFlow via the public purchase flow
        // We need to create a checkout session without opening Safari
        guard ZeroSettleIAP.shared.isConfigured else {
            error = ZeroSettleIAPError.notConfigured
            return
        }

        do {
            let session = try await createSession(productId: productId, userId: userId)
            transactionId = session.transactionId
            checkoutURL = session.checkoutUrl
            Logger.info("Checkout session created for WebView: \(session.sessionId)", category: .iap)
        } catch {
            Logger.error("Failed to create checkout session: \(error)", category: .iap)
            self.error = error
        }
    }

    func verifyTransaction(transactionId: String) async throws -> ZSTransaction {
        let transaction = try await getTransaction(transactionId: transactionId)

        guard transaction.status == .completed else {
            throw CheckoutError.transactionVerificationFailed(
                "Transaction status: \(transaction.status.rawValue)"
            )
        }

        return transaction
    }

    // MARK: - Private API Access

    /// Create a checkout session by directly calling the backend API.
    /// This duplicates some logic from WebCheckoutFlow but avoids opening Safari.
    private func createSession(productId: String, userId: String) async throws -> CheckoutSession {
        let backend = try getBackend()
        return try await backend.createCheckoutSession(productId: productId, userId: userId)
    }

    private func getTransaction(transactionId: String) async throws -> ZSTransaction {
        let backend = try getBackend()
        return try await backend.getTransaction(transactionId: transactionId)
    }

    private func getBackend() throws -> Backend {
        guard let config = ZeroSettleIAP.shared.currentConfig,
              let baseURL = ZeroSettleIAP.shared.effectiveBaseURL else {
            throw ZeroSettleIAPError.notConfigured
        }
        return Backend(baseURL: baseURL, publishableKey: config.publishableKey)
    }
}

// MARK: - Checkout Session WebView

private struct CheckoutSessionWebView: UIViewRepresentable {
    let url: URL
    let onComplete: (WebViewCheckoutResult) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Add JavaScript message handler for checkout completion
        let contentController = configuration.userContentController
        contentController.add(context.coordinator, name: "checkoutComplete")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false

        // Load the checkout URL
        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onComplete: (WebViewCheckoutResult) -> Void
        private var hasCompleted = false

        init(onComplete: @escaping (WebViewCheckoutResult) -> Void) {
            self.onComplete = onComplete
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "checkoutComplete",
                  let body = message.body as? [String: Any] else {
                return
            }

            guard !hasCompleted else { return }
            hasCompleted = true

            if let success = body["success"] as? Bool, success,
               let transactionId = body["transaction_id"] as? String {
                Logger.info("WebView checkout completed: \(transactionId)", category: .iap)
                onComplete(.success(transactionId: transactionId))
            } else if let cancelled = body["cancelled"] as? Bool, cancelled {
                Logger.info("WebView checkout cancelled", category: .iap)
                onComplete(.cancelled)
            } else {
                let errorMessage = body["error"] as? String ?? "Unknown error"
                Logger.error("WebView checkout failed: \(errorMessage)", category: .iap)
                onComplete(.failure(CheckoutError.webViewError(errorMessage)))
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Check if this is a callback URL
            if let url = navigationAction.request.url,
               isCallbackURL(url) {
                handleCallbackURL(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !hasCompleted else { return }
            hasCompleted = true

            Logger.error("WebView navigation failed: \(error)", category: .iap)
            onComplete(.failure(CheckoutError.webViewError(error.localizedDescription)))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            guard !hasCompleted else { return }
            hasCompleted = true

            Logger.error("WebView provisional navigation failed: \(error)", category: .iap)
            onComplete(.failure(CheckoutError.webViewError(error.localizedDescription)))
        }

        // MARK: - Callback URL Handling

        private let callbackHosts = ["api.zerosettle.io", "landing.zerosettle.ngrok.app"]
        private let callbackPathPrefix = "/checkout/callback"

        private func isCallbackURL(_ url: URL) -> Bool {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let host = components.host,
                  let path = components.path.removingPercentEncoding else {
                return false
            }

            return callbackHosts.contains(host) && path.hasPrefix(callbackPathPrefix)
        }

        private func handleCallbackURL(_ url: URL) {
            guard !hasCompleted else { return }
            hasCompleted = true

            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                onComplete(.failure(CheckoutError.webViewError("Invalid callback URL")))
                return
            }

            let queryItems = components.queryItems ?? []
            let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
                item.value.map { (item.name, $0) }
            })

            guard let transactionId = params["transaction_id"],
                  let statusString = params["status"] else {
                onComplete(.failure(CheckoutError.webViewError("Missing callback parameters")))
                return
            }

            if statusString == "success" {
                Logger.info("WebView callback: success, transaction=\(transactionId)", category: .iap)
                onComplete(.success(transactionId: transactionId))
            } else {
                Logger.info("WebView callback: cancelled", category: .iap)
                onComplete(.cancelled)
            }
        }
    }
}
