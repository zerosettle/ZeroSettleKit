//
//  ZSPaymentSheet.swift
//  ZeroSettleIAP
//
//  An embedded payment sheet that loads the ZeroSettle checkout page
//  in a WKWebView. Starts compact showing product info + payment method
//  selection, expands to full height when card entry is needed.
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
import ZeroSettleCore
#endif

// MARK: - Payment Sheet

/// An embedded payment sheet for ZeroSettle web checkout.
///
/// Presents an optional native SwiftUI header above a WebView with
/// payment buttons. Tapping Apple Pay triggers the Payment Request API
/// inline. Tapping Card expands the sheet to show the Stripe card entry form.
///
/// Supply a `@ViewBuilder` header to render product info natively above
/// the payment buttons, or omit the header for a payment-buttons-only sheet.
public struct ZSPaymentSheet<Header: View>: View {

    // MARK: - Configuration

    private let product: Product
    private let userId: String
    private let prefetchedCheckoutURL: URL?
    private let prefetchedTransactionId: String?
    private let header: Header
    private let onComplete: (Result<ZSTransaction, Error>) -> Void

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    @State private var checkoutURL: URL?
    @State private var isLoading = true
    @State private var loadError: Error?
    @State private var transactionId: String?
    @State private var compactHeight: CGFloat = 480
    @State private var headerHeight: CGFloat = 0
    @State private var selectedDetent: PresentationDetent = .height(480)

    // MARK: - Initialization

    public init(
        product: Product,
        userId: String,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        self.product = product
        self.userId = userId
        self.prefetchedCheckoutURL = checkoutURL
        self.prefetchedTransactionId = transactionId
        self.header = header()
        self.onComplete = onComplete
    }

}

extension ZSPaymentSheet where Header == EmptyView {
    /// Creates a payment sheet without a native header — shows only payment buttons.
    public init(
        product: Product,
        userId: String,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        self.init(
            product: product,
            userId: userId,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            header: { EmptyView() },
            onComplete: onComplete
        )
    }

    /// Pre-create a PaymentIntent and return the checkout URL.
    /// Call this before presenting ZSPaymentSheet to eliminate load time.
    public static func preload(
        productId: String,
        userId: String
    ) async -> (checkoutURL: URL, transactionId: String)? {
        guard let config = ZeroSettleIAP.shared.currentConfig,
              let baseURL = ZeroSettleIAP.shared.effectiveBaseURL else { return nil }

        do {
            let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
            let paymentIntent = try await backend.createPaymentIntent(productId: productId, userId: userId)
            guard let url = URL(string: paymentIntent.checkoutUrl) else { return nil }
            return (url, paymentIntent.transactionId)
        } catch {
            return nil
        }
    }
}

extension ZSPaymentSheet {
    // MARK: - Body

    public var body: some View {
        ZStack {
            // Solid fill so the sheet is fully opaque in every state
            Color(.systemBackground)
                .ignoresSafeArea()

            if let error = loadError {
                errorView(error)
            } else if let url = checkoutURL {
                VStack(spacing: 0) {
                    if !(Header.self == EmptyView.self) {
                        header
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
                            })
                    }

                    PaymentWebView(
                        url: url,
                        isLoading: $isLoading,
                        onAction: handleWebViewAction
                    )
                    .ignoresSafeArea(.container, edges: .bottom)
                }
                .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }

                // Loading overlay while WebView content loads
                if isLoading {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading checkout...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Loading while creating PaymentIntent
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Preparing checkout...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .presentationDetents([.height(compactHeight), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .presentationBackgroundInteraction(.disabled)
        .task {
            if let url = prefetchedCheckoutURL {
                self.checkoutURL = url
                self.transactionId = prefetchedTransactionId
            } else {
                await createPaymentIntent()
            }
        }
    }

    // MARK: - Error View

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Unable to load checkout")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                loadError = nil
                Task {
                    await createPaymentIntent()
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") {
                dismiss()
                onComplete(.failure(PaymentSheetError.cancelled))
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func createPaymentIntent() async {
        guard let config = ZeroSettleIAP.shared.currentConfig,
              let baseURL = ZeroSettleIAP.shared.effectiveBaseURL else {
            await MainActor.run {
                loadError = PaymentSheetError.notConfigured
            }
            return
        }

        do {
            let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
            let paymentIntent = try await backend.createPaymentIntent(productId: product.id, userId: userId)

            await MainActor.run {
                self.transactionId = paymentIntent.transactionId
                self.checkoutURL = URL(string: paymentIntent.checkoutUrl)
            }
        } catch {
            await MainActor.run {
                loadError = error
            }
        }
    }

    private func handleWebViewAction(_ action: WebViewAction) {
        switch action {
        case .ready:
            // Page loaded and Stripe initialized
            break

        case .contentHeight(let webContentHeight):
            let totalHeight = headerHeight + webContentHeight + 32
            let clamped = min(max(totalHeight, 200), 600)
            withAnimation(.easeInOut(duration: 0.3)) {
                compactHeight = clamped
                selectedDetent = .height(clamped)
            }

        case .expandSheet:
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedDetent = .large
            }

        case .collapseSheet:
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedDetent = .height(compactHeight)
            }

        case .complete(let txnId):
            Task {
                await verifyAndComplete(transactionId: txnId)
            }

        case .cancelled:
            dismiss()
            onComplete(.failure(PaymentSheetError.cancelled))

        case .error(let message):
            dismiss()
            onComplete(.failure(PaymentSheetError.paymentFailed(message)))
        }
    }

    private func verifyAndComplete(transactionId: String) async {
        guard let config = ZeroSettleIAP.shared.currentConfig,
              let baseURL = ZeroSettleIAP.shared.effectiveBaseURL else {
            await MainActor.run {
                dismiss()
                onComplete(.failure(PaymentSheetError.notConfigured))
            }
            return
        }

        do {
            let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
            let transaction = try await backend.getTransaction(transactionId: transactionId)
            await MainActor.run {
                dismiss()
                onComplete(.success(transaction))
            }
        } catch {
            await MainActor.run {
                dismiss()
                onComplete(.failure(error))
            }
        }
    }
}

// MARK: - Header Height Preference Key

private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - WebView Action

private enum WebViewAction {
    case ready
    case contentHeight(CGFloat)
    case expandSheet
    case collapseSheet
    case complete(transactionId: String)
    case cancelled
    case error(String)
}

// MARK: - Payment WebView

private struct PaymentWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onAction: (WebViewAction) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "checkoutComplete")
        configuration.userContentController.add(context.coordinator, name: "consoleLog")

        // Forward JS console.log/warn/error to native
        let consoleScript = WKUserScript(source: """
            (function() {
                function forward(level) {
                    var orig = console[level];
                    console[level] = function() {
                        var args = Array.prototype.slice.call(arguments).map(function(a) {
                            try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                            catch(e) { return String(a); }
                        });
                        window.webkit.messageHandlers.consoleLog.postMessage({
                            level: level,
                            message: args.join(' ')
                        });
                        orig.apply(console, arguments);
                    };
                }
                forward('log'); forward('warn'); forward('error');
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(consoleScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        context.coordinator.webView = webView

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onAction: onAction)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var isLoading: Bool
        let onAction: (WebViewAction) -> Void
        weak var webView: WKWebView?
        private var hasCompleted = false

        private let callbackHosts = [
            "api.zerosettle.io",
            "zerosettle.io",
            "landing.zerosettle.ngrok.app",
            "api.zerosettle.ngrok.app"
        ]
        private let callbackPathPrefix = "/checkout/callback"

        init(isLoading: Binding<Bool>, onAction: @escaping (WebViewAction) -> Void) {
            self._isLoading = isLoading
            self.onAction = onAction
        }

        // MARK: - JS Message Handler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Forward JS console output to Xcode console
            if message.name == "consoleLog",
               let body = message.body as? [String: Any],
               let level = body["level"] as? String,
               let msg = body["message"] as? String {
                print("[WebView \(level)] \(msg)")
                return
            }

            guard message.name == "checkoutComplete",
                  let body = message.body as? [String: Any] else { return }

            let action = body["action"] as? String ?? ""

            switch action {
            case "ready":
                onAction(.ready)
                // Measure actual content height (body has min-height:100% so scrollHeight is unreliable)
                let measureJS = """
                (function() {
                    var el = document.getElementById('checkout-content');
                    if (el) {
                        var rect = el.getBoundingClientRect();
                        return rect.top + rect.height;
                    }
                    var children = document.body.children;
                    var maxBottom = 0;
                    for (var i = 0; i < children.length; i++) {
                        if (children[i].offsetHeight > 0) {
                            var r = children[i].getBoundingClientRect();
                            if (r.bottom > maxBottom) maxBottom = r.bottom;
                        }
                    }
                    return maxBottom;
                })()
                """
                webView?.evaluateJavaScript(measureJS) { [weak self] result, _ in
                    guard let self = self else { return }
                    if let height = result as? CGFloat, height > 0 {
                        self.onAction(.contentHeight(height))
                    } else if let number = result as? NSNumber, number.doubleValue > 0 {
                        self.onAction(.contentHeight(CGFloat(number.doubleValue)))
                    }
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                }

            case "expandSheet":
                onAction(.expandSheet)

            case "collapseSheet":
                onAction(.collapseSheet)

            case "complete":
                guard !hasCompleted else { return }
                hasCompleted = true
                if let success = body["success"] as? Bool, success,
                   let transactionId = body["transaction_id"] as? String {
                    onAction(.complete(transactionId: transactionId))
                } else {
                    let errorMessage = body["error"] as? String ?? "Payment failed"
                    onAction(.error(errorMessage))
                }

            case "error":
                let errorMessage = body["message"] as? String ?? "Checkout error"
                onAction(.error(errorMessage))

            default:
                // Legacy format (no action field) — treat as completion
                guard !hasCompleted else { return }
                hasCompleted = true
                if let success = body["success"] as? Bool, success,
                   let transactionId = body["transaction_id"] as? String {
                    onAction(.complete(transactionId: transactionId))
                } else if let cancelled = body["cancelled"] as? Bool, cancelled {
                    onAction(.cancelled)
                } else {
                    let errorMessage = body["error"] as? String ?? "Payment failed"
                    onAction(.error(errorMessage))
                }
            }
        }

        // MARK: - Navigation Delegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Don't dismiss loading overlay here — wait for JS 'ready' message
            // so Stripe.js has finished initializing before showing content.
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, isCallbackURL(url) {
                handleCallbackURL(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: - Callback Handling

        private func isCallbackURL(_ url: URL) -> Bool {
            guard let host = url.host,
                  callbackHosts.contains(host),
                  url.path.hasPrefix(callbackPathPrefix) else {
                return false
            }
            return true
        }

        private func handleCallbackURL(_ url: URL) {
            guard !hasCompleted else { return }
            hasCompleted = true

            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                onAction(.error("Invalid callback URL"))
                return
            }

            let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })

            guard let transactionId = params["transaction_id"], let status = params["status"] else {
                onAction(.error("Missing callback parameters"))
                return
            }

            if status == "success" {
                onAction(.complete(transactionId: transactionId))
            } else {
                onAction(.cancelled)
            }
        }
    }
}

// MARK: - Payment Sheet Error

public enum PaymentSheetError: Error, LocalizedError {
    case cancelled
    case notConfigured
    case presentationFailed
    case invalidCard
    case paymentFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Payment was cancelled"
        case .notConfigured: return "ZeroSettle is not configured"
        case .presentationFailed: return "Unable to present payment UI"
        case .invalidCard: return "Please enter valid card details"
        case .paymentFailed(let message): return message
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ZSPaymentSheet_Previews: PreviewProvider {
    static var previews: some View {
        ZSPaymentSheet(
            product: Product(
                id: "premium_monthly",
                displayName: "Premium Monthly",
                productDescription: "Unlock all features",
                type: .autoRenewableSubscription,
                webPrice: Price(amountMicros: 4_990_000, currencyCode: "USD"),
                appStorePrice: Price(amountMicros: 5_990_000, currencyCode: "USD")
            ),
            userId: "user_123"
        ) { _ in }
    }
}
#endif
