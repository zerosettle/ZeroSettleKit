//
//  ZSPaymentSheet.swift
//  ZeroSettleIAP
//
//  An embedded payment sheet that loads the ZeroSettle checkout page
//  in a WKWebView. The WebView is preloaded off-screen before the
//  sheet appears, so the user sees a fully-rendered checkout instantly.
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
import ZeroSettleCore
#endif

// MARK: - Message Router

/// Proxy WKScriptMessageHandler that forwards messages to a mutable closure.
/// Lets us redirect WebView messages between preloader and sheet phases.
private final class MessageRouter: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        onMessage?(message)
    }
}

// MARK: - Checkout Preloader

/// Manages off-screen WKWebView creation and preloading.
/// Creates the WebView, loads the checkout URL, and waits for the
/// JavaScript "ready" signal before resolving.
private final class CheckoutPreloader: ObservableObject {
    @Published var webView: WKWebView?
    @Published private(set) var isReady = false
    private(set) var measuredContentHeight: CGFloat = 0
    private(set) var startedExpanded = false
    let messageRouter = MessageRouter()
    private var continuation: CheckedContinuation<Void, Never>?

    @MainActor
    func loadAndWait(url: URL) async {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Use non-persistent data store to prevent caching between sessions
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(messageRouter, name: "checkoutComplete")
        config.userContentController.add(messageRouter, name: "consoleLog")

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
        config.userContentController.addUserScript(consoleScript)

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 600), configuration: config)
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear

        self.webView = wv
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        wv.load(request)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont

            messageRouter.onMessage = { [weak self] message in
                guard let self = self else { return }

                if message.name == "consoleLog",
                   let body = message.body as? [String: Any],
                   let level = body["level"] as? String,
                   let msg = body["message"] as? String {
                    print("[WebView \(level)] \(msg)")
                    return
                }

                guard message.name == "checkoutComplete",
                      let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }

                if action == "expandSheet" {
                    self.startedExpanded = true
                    return
                }

                guard action == "ready" else { return }

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
                self.webView?.evaluateJavaScript(measureJS) { [weak self] result, _ in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if let height = result as? CGFloat, height > 0 {
                            self.measuredContentHeight = height
                        } else if let number = result as? NSNumber, number.doubleValue > 0 {
                            self.measuredContentHeight = CGFloat(number.doubleValue)
                        }
                        self.isReady = true
                        self.continuation?.resume()
                        self.continuation = nil
                    }
                }
            }
        }
    }

    func reset() {
        webView = nil
        isReady = false
        measuredContentHeight = 0
        startedExpanded = false
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Preloader Host

/// Invisible view that hosts the preloader's WKWebView in the hierarchy.
/// WKWebView must be in a window to load and render content.
private struct PreloaderHost: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        for subview in uiView.subviews where subview !== webView {
            subview.removeFromSuperview()
        }
        if let wv = webView, wv.superview == nil {
            wv.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
            uiView.addSubview(wv)
        }
    }
}

// MARK: - Payment Sheet

/// An embedded payment sheet for ZeroSettle web checkout.
///
/// Presents an optional native SwiftUI header above a WebView with
/// payment buttons. The WebView is preloaded before the sheet appears.
public struct ZSPaymentSheet<Header: View>: View {

    // MARK: - Configuration

    private let product: Product
    private let userId: String
    private let prefetchedCheckoutURL: URL?
    private let prefetchedTransactionId: String?
    private let preloadedWebView: WKWebView?
    private let messageRouter: MessageRouter?
    private let initialContentHeight: CGFloat
    private let header: Header
    private let onComplete: (Result<ZSTransaction, Error>) -> Void

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    @State private var checkoutURL: URL?
    @State private var isLoading: Bool
    @State private var loadError: Error?
    @State private var transactionId: String?
    @State private var webContentHeight: CGFloat
    @State private var compactHeight: CGFloat
    @State private var headerHeight: CGFloat = 0
    @State private var selectedDetent: PresentationDetent
    @State private var isExpanded = false

    // MARK: - Public Initialization (without preloading)

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
        self.preloadedWebView = nil
        self.messageRouter = nil
        self.initialContentHeight = 0
        self.header = header()
        self.onComplete = onComplete
        self._isLoading = State(initialValue: true)
        self._webContentHeight = State(initialValue: 0)
        self._compactHeight = State(initialValue: 480)
        self._selectedDetent = State(initialValue: .height(480))
    }

    // MARK: - Internal Initialization (with preloaded WebView)

    fileprivate init(
        product: Product,
        userId: String,
        preloader: CheckoutPreloader,
        checkoutURL: URL,
        transactionId: String?,
        @ViewBuilder header: () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        self.product = product
        self.userId = userId
        self.prefetchedCheckoutURL = checkoutURL
        self.prefetchedTransactionId = transactionId
        self.preloadedWebView = preloader.webView
        self.messageRouter = preloader.messageRouter
        self.initialContentHeight = preloader.measuredContentHeight
        self.header = header()
        self.onComplete = onComplete
        self._isLoading = State(initialValue: false)
        self._webContentHeight = State(initialValue: preloader.measuredContentHeight)
        let startHeight = min(max(preloader.measuredContentHeight, 200), 700)
        self._compactHeight = State(initialValue: startHeight)
        self._isExpanded = State(initialValue: preloader.startedExpanded)
        self._selectedDetent = State(initialValue: preloader.startedExpanded ? .large : .height(startHeight))
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
        VStack(spacing: 0) {
            if let error = loadError {
                errorView(error)
            } else if let url = checkoutURL {
                if !(Header.self == EmptyView.self) {
                    header
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 20)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
                        })
                        .onPreferenceChange(HeaderHeightKey.self) { newHeight in
                            headerHeight = newHeight
                            recalculateHeight()
                        }
                }

                ZStack {
                    PaymentWebView(
                        url: url,
                        isLoading: $isLoading,
                        preloadedWebView: preloadedWebView,
                        messageRouter: messageRouter,
                        onAction: handleWebViewAction
                    )

                    if isLoading {
                        Color(.systemBackground)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
                onComplete(.failure(PaymentSheetError.cancelled))
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 14)
            .padding(.trailing, 18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
        .presentationDetents(isExpanded ? [.height(compactHeight), .large] : [.height(compactHeight)], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .interactiveDismissDisabled()
        .task {
            if let url = prefetchedCheckoutURL {
                self.checkoutURL = url
                self.transactionId = prefetchedTransactionId
            } else {
                await createPaymentIntent()
            }
        }
    }

    // MARK: - Height Calculation

    private func recalculateHeight() {
        let contentH = webContentHeight > 0 ? webContentHeight : 400
        let totalHeight = headerHeight + contentH
        let clamped = min(max(totalHeight, 200), 700)

        withAnimation(.easeInOut(duration: 0.3)) {
            compactHeight = clamped
            if !isExpanded {
                selectedDetent = .height(clamped)
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
            break

        case .contentHeight(let height):
            webContentHeight = height
            recalculateHeight()

        case .expandSheet:
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = true
                selectedDetent = .large
            }

        case .collapseSheet:
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedDetent = .height(compactHeight)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isExpanded = false
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
    var preloadedWebView: WKWebView?
    var messageRouter: MessageRouter?
    let onAction: (WebViewAction) -> Void

    func makeUIView(context: Context) -> WKWebView {
        // Reuse preloaded WebView if available
        if let preloaded = preloadedWebView {
            preloaded.removeFromSuperview()
            preloaded.navigationDelegate = context.coordinator
            context.coordinator.webView = preloaded

            messageRouter?.onMessage = { [weak coordinator = context.coordinator] message in
                guard let coordinator = coordinator else { return }
                coordinator.userContentController(WKUserContentController(), didReceive: message)
            }

            return preloaded
        }

        // Standard path: create a new WebView
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // Use non-persistent data store to prevent caching between sessions
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "checkoutComplete")
        configuration.userContentController.add(context.coordinator, name: "consoleLog")

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
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.webView = webView

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}

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

// MARK: - SwiftUI View Modifier

/// Preloads the PaymentIntent AND the WebView before presenting the sheet.
/// The user sees a fully-rendered checkout the moment it slides up.
private struct ZSPaymentSheetModifier<Header: View>: ViewModifier {
    @Binding var isPresented: Bool
    let product: Product
    let userId: String
    let header: () -> Header
    let onComplete: (Result<ZSTransaction, Error>) -> Void

    @StateObject private var preloader = CheckoutPreloader()
    @State private var showSheet = false
    @State private var preloadedURL: URL?
    @State private var preloadedTransactionId: String?

    func body(content: Content) -> some View {
        content
            .background(
                PreloaderHost(webView: preloader.webView)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            )
            .task(id: isPresented) {
                if isPresented {
                    await preloadAll()
                } else {
                    showSheet = false
                    preloadedURL = nil
                    preloadedTransactionId = nil
                    preloader.reset()
                }
            }
            .sheet(isPresented: $showSheet, onDismiss: {
                isPresented = false
                preloadedURL = nil
                preloadedTransactionId = nil
                preloader.reset()
            }) {
                if let url = preloadedURL {
                    ZSPaymentSheet(
                        product: product,
                        userId: userId,
                        preloader: preloader,
                        checkoutURL: url,
                        transactionId: preloadedTransactionId,
                        header: header,
                        onComplete: onComplete
                    )
                } else {
                    ZSPaymentSheet(
                        product: product,
                        userId: userId,
                        header: header,
                        onComplete: onComplete
                    )
                }
            }
    }

    private func preloadAll() async {
        guard let result = await ZSPaymentSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else { return }
            showSheet = true
            return
        }

        guard !Task.isCancelled else { return }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        await preloader.loadAndWait(url: result.checkoutURL)

        guard !Task.isCancelled else { return }
        showSheet = true
    }
}

// MARK: - Item-Based Modifier

/// Presents the payment sheet driven by an optional `Product?` binding.
/// When `item` becomes non-nil the sheet presents; on dismiss it's set back to `nil`.
private struct ZSPaymentSheetItemModifier<Header: View>: ViewModifier {
    @Binding var item: Product?
    let userId: String
    let header: () -> Header
    let onComplete: (Result<ZSTransaction, Error>) -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { item != nil },
            set: { if !$0 { item = nil } }
        )
    }

    func body(content: Content) -> some View {
        if let product = item {
            content.modifier(ZSPaymentSheetModifier(
                isPresented: isPresented,
                product: product,
                userId: userId,
                header: header,
                onComplete: onComplete
            ))
        } else {
            content
        }
    }
}

extension View {
    /// Presents a ZeroSettle payment sheet when `isPresented` is true.
    ///
    /// The PaymentIntent and WebView are preloaded before the sheet appears,
    /// so the checkout is ready for interaction the moment it slides up.
    public func zsPaymentSheet(
        isPresented: Binding<Bool>,
        product: Product,
        userId: String,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetModifier<EmptyView>(
            isPresented: isPresented,
            product: product,
            userId: userId,
            header: { EmptyView() },
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet with a custom header when `isPresented` is true.
    public func zsPaymentSheet<Header: View>(
        isPresented: Binding<Bool>,
        product: Product,
        userId: String,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetModifier(
            isPresented: isPresented,
            product: product,
            userId: userId,
            header: header,
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet driven by an optional product binding.
    ///
    /// When `item` is non-nil, the sheet presents for that product.
    /// On dismiss, `item` is automatically set back to `nil`.
    ///
    ///     .zsPaymentSheet(item: $selectedProduct, userId: "user_123") { result in
    ///         print(result)
    ///     }
    public func zsPaymentSheet(
        item: Binding<Product?>,
        userId: String,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetItemModifier<EmptyView>(
            item: item,
            userId: userId,
            header: { EmptyView() },
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet with a custom header, driven by an optional product binding.
    public func zsPaymentSheet<Header: View>(
        item: Binding<Product?>,
        userId: String,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetItemModifier(
            item: item,
            userId: userId,
            header: header,
            onComplete: onComplete
        ))
    }
}

// MARK: - UIKit Presentation

extension ZSPaymentSheet where Header == EmptyView {
    /// Present a ZeroSettle payment sheet from a UIKit view controller.
    @MainActor
    public static func present(
        from viewController: UIViewController,
        product: Product,
        userId: String,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        weak var bridgeController: UIViewController?

        let bridge = PaymentSheetBridge(
            product: product,
            userId: userId,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            onComplete: onComplete,
            onDismissed: {
                bridgeController?.dismiss(animated: false)
            }
        )

        let hosting = UIHostingController(rootView: bridge)
        hosting.view.backgroundColor = .clear
        hosting.modalPresentationStyle = .overFullScreen
        bridgeController = hosting
        viewController.present(hosting, animated: false)
    }
}

/// Transparent bridge that presents ZSPaymentSheet via SwiftUI's `.sheet`
/// so all presentation modifiers work correctly when called from UIKit.
private struct PaymentSheetBridge: View {
    let product: Product
    let userId: String
    let checkoutURL: URL?
    let transactionId: String?
    let onComplete: (Result<ZSTransaction, Error>) -> Void
    let onDismissed: () -> Void

    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented, onDismiss: onDismissed) {
                ZSPaymentSheet(
                    product: product,
                    userId: userId,
                    checkoutURL: checkoutURL,
                    transactionId: transactionId,
                    onComplete: onComplete
                )
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
