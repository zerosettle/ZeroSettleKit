//
//  ZSPaymentSheet.swift
//  ZeroSettleKit
//
//  An embedded payment sheet that loads the ZeroSettle checkout page
//  in a WKWebView. The WebView is preloaded off-screen before the
//  sheet appears, so the user sees a fully-rendered checkout instantly.
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
@_implementationOnly import ZeroSettleCore
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
        let trace = PaymentSheetTrace.current
        let outerSpan = trace?.begin("webView.loadAndWait")

        let createSpan = trace?.begin("webView.create")
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
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
        if let createSpan { trace?.end(createSpan) }

        self.webView = wv

        let loadSpan = trace?.begin("webView.loadURL")
        PaymentSheetTrace.logger.info("⏱  ▶ webView.loadURL: \(url.absoluteString)")
        let request = URLRequest(url: url)
        wv.load(request)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont

            messageRouter.onMessage = { [weak self] message in
                guard let self = self else { return }

                if message.name == "consoleLog",
                   let body = message.body as? [String: Any],
                   let level = body["level"] as? String,
                   let msg = body["message"] as? String {
                    PaymentSheetTrace.logger.debug("⏱  [WebView \(level)] \(msg)")
                    return
                }

                guard message.name == "checkoutComplete",
                      let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }

                if action == "expandSheet" {
                    trace?.event("JS: expandSheet (preload phase)")
                    self.startedExpanded = true
                    return
                }

                guard action == "ready" else {
                    trace?.event("JS: \(action) (preload phase)")
                    return
                }

                if let loadSpan { trace?.end(loadSpan) }
                let readySpan = trace?.begin("webView.measureContent")

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
                        if let readySpan { trace?.end(readySpan, metadata: ["height": "\(self.measuredContentHeight)"]) }
                        if let outerSpan { trace?.end(outerSpan) }
                        self.isReady = true
                        self.continuation?.resume()
                        self.continuation = nil
                    }
                }
            }
        }
    }

    func reset() {
        PaymentSheetTrace.logger.debug("⏱  ● preloader.reset()")
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

// MARK: - Checkout Cache

/// Caches PaymentIntent results (checkout URL + transaction ID) so re-opens
/// skip the network call entirely. Thread-safe via NSLock.
private final class CheckoutCache {
    static let shared = CheckoutCache()

    private struct Entry {
        let checkoutURL: URL
        let transactionId: String
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 300 // 5 minutes

    private init() {}

    func get(productId: String, userId: String?) -> (checkoutURL: URL, transactionId: String)? {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(productId):\(userId ?? "")"
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.timestamp) < ttl else {
            entries.removeValue(forKey: key)
            return nil
        }
        return (entry.checkoutURL, entry.transactionId)
    }

    func set(productId: String, userId: String?, checkoutURL: URL, transactionId: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(productId):\(userId ?? "")"
        entries[key] = Entry(checkoutURL: checkoutURL, transactionId: transactionId, timestamp: Date())
    }

    func invalidate(productId: String, userId: String?) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: "\(productId):\(userId ?? "")")
    }
}

// MARK: - Payment Sheet

/// An embedded payment sheet for ZeroSettle web checkout.
///
/// Presents an optional native SwiftUI header above a WebView with
/// payment buttons. The WebView is preloaded before the sheet appears.
public struct ZSPaymentSheet<Header: View>: View {

    // MARK: - Configuration

    private let product: ZSProduct
    private let userId: String?
    private let dismissible: Bool
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
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        self.product = product
        self.userId = userId
        self.dismissible = dismissible
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
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        preloader: CheckoutPreloader,
        checkoutURL: URL,
        transactionId: String?,
        @ViewBuilder header: () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        self.product = product
        self.userId = userId
        self.dismissible = dismissible
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
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        self.init(
            product: product,
            userId: userId,
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            header: { EmptyView() },
            onComplete: onComplete
        )
    }

    /// Pre-create a PaymentIntent and return the checkout URL.
    /// Results are cached for 5 minutes so repeated opens skip the API call.
    /// Returns `nil` immediately for non-webview checkout types (no API call needed).
    public static func preload(
        productId: String,
        userId: String? = nil
    ) async -> (checkoutURL: URL, transactionId: String)? {
        // Only webview checkout uses PaymentIntents — safari/safariVC use checkout sessions
        guard ZeroSettle.shared.checkoutType == .webview else { return nil }
        let trace = PaymentSheetTrace.current
        let span = trace?.begin("createPaymentIntent", metadata: ["productId": productId])

        // Check cache first
        let cacheSpan = trace?.begin("cache.lookup")
        if let cached = CheckoutCache.shared.get(productId: productId, userId: userId) {
            if let cacheSpan { trace?.end(cacheSpan, metadata: ["result": "HIT"]) }
            if let span { trace?.end(span, metadata: ["source": "cache"]) }
            return cached
        }
        if let cacheSpan { trace?.end(cacheSpan, metadata: ["result": "MISS"]) }

        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            trace?.event("createPaymentIntent: SDK not configured")
            if let span { trace?.end(span, metadata: ["error": "notConfigured"]) }
            return nil
        }

        do {
            let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
            let paymentIntent = try await backend.createPaymentIntent(productId: productId, userId: userId)
            guard let url = URL(string: paymentIntent.checkoutUrl) else {
                if let span { trace?.end(span, metadata: ["error": "invalidURL"]) }
                return nil
            }

            // Cache for re-use
            CheckoutCache.shared.set(
                productId: productId, userId: userId,
                checkoutURL: url, transactionId: paymentIntent.transactionId
            )
            trace?.event("cache.store", metadata: ["txnId": paymentIntent.transactionId])

            // Prefetch the checkout page to prime DNS, TLS, and URL cache
            let prefetchSpan = trace?.begin("prefetch")
            _ = try? await URLSession.shared.data(from: url)
            if let prefetchSpan { trace?.end(prefetchSpan) }

            if let span { trace?.end(span, metadata: ["source": "network"]) }
            return (url, paymentIntent.transactionId)
        } catch {
            if let span { trace?.end(span, metadata: ["error": "\(error)"]) }
            return nil
        }
    }

    /// Pre-caches the PaymentIntent for a product so the sheet opens faster later.
    /// Call this when your product list loads to eliminate first-open delay.
    ///
    ///     .task {
    ///         let products = try await iap.fetchProducts()
    ///         await ZSPaymentSheet.warmUp(productId: products[0].id, userId: "user_123")
    ///     }
    public static func warmUp(productId: String, userId: String? = nil) async {
        let trace = PaymentSheetTrace("warmUp")
        PaymentSheetTrace.current = trace
        _ = await preload(productId: productId, userId: userId)
        trace.finish()
    }
}

extension ZSPaymentSheet {
    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            if let error = loadError {
                errorView(error)
            } else if let url = checkoutURL {
                if Header.self == EmptyView.self {
                    defaultHeader
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
                        })
                        .onPreferenceChange(HeaderHeightKey.self) { newHeight in
                            headerHeight = newHeight
                            recalculateHeight()
                        }
                } else {
                    header
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
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
            if dismissible {
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
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
        .presentationDetents(isExpanded ? [.height(compactHeight), .large] : [.height(compactHeight)], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .interactiveDismissDisabled(!dismissible)
        .task {
            // Validate userId for subscription/non-consumable products
            if userId == nil {
                let type = product.type
                if type == .autoRenewableSubscription || type == .nonRenewingSubscription || type == .nonConsumable {
                    loadError = PaymentSheetError.userIdRequired
                    return
                }
            }

            if let url = prefetchedCheckoutURL {
                self.checkoutURL = url
                self.transactionId = prefetchedTransactionId
            } else {
                await createPaymentIntent()
            }
        }
    }

    // MARK: - Default Header

    private var defaultHeader: some View {
        Text(product.displayName)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    // MARK: - Height Calculation

    private func recalculateHeight() {
        let contentH = webContentHeight > 0 ? webContentHeight : 400
        let totalHeight = headerHeight + contentH
        let newHeight = min(max(totalHeight, 200), 700)

        guard newHeight != compactHeight else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            compactHeight = newHeight
            if !isExpanded {
                selectedDetent = .height(newHeight)
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
        PaymentSheetTrace.logger.debug("⏱  ▶ createPaymentIntent (direct, no preloader)")
        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            PaymentSheetTrace.logger.error("⏱  ◀ createPaymentIntent: SDK not configured")
            await MainActor.run {
                loadError = PaymentSheetError.notConfigured
            }
            return
        }

        do {
            let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
            let paymentIntent = try await backend.createPaymentIntent(productId: product.id, userId: userId)
            PaymentSheetTrace.logger.debug("⏱  ◀ createPaymentIntent: txnId=\(paymentIntent.transactionId)")

            await MainActor.run {
                self.transactionId = paymentIntent.transactionId
                self.checkoutURL = URL(string: paymentIntent.checkoutUrl)
            }
        } catch {
            PaymentSheetTrace.logger.error("⏱  ◀ createPaymentIntent: error=\(error)")
            await MainActor.run {
                loadError = error
            }
        }
    }

    private func handleWebViewAction(_ action: WebViewAction) {
        switch action {
        case .ready:
            PaymentSheetTrace.logger.debug("⏱  ● JS → ready (in-sheet)")
            break

        case .contentHeight(let height):
            PaymentSheetTrace.logger.debug("⏱  ● JS → contentHeight: \(height)")
            webContentHeight = height
            recalculateHeight()

        case .expandSheet:
            PaymentSheetTrace.logger.debug("⏱  ● JS → expandSheet (user interacting with card form)")
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = true
                selectedDetent = .large
            }

        case .collapseSheet:
            PaymentSheetTrace.logger.debug("⏱  ● JS → collapseSheet")
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedDetent = .height(compactHeight)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isExpanded = false
            }

        case .complete(let txnId):
            PaymentSheetTrace.logger.info("⏱  ● JS → complete (txnId=\(txnId))")
            Task {
                await verifyAndComplete(transactionId: txnId)
            }

        case .cancelled:
            PaymentSheetTrace.logger.debug("⏱  ● JS → cancelled")
            dismiss()
            onComplete(.failure(PaymentSheetError.cancelled))

        case .error(let message):
            PaymentSheetTrace.logger.error("⏱  ● JS → error: \(message)")
            dismiss()
            let kind: PaymentFailureDetail.Kind
            let lowered = message.lowercased()
            if lowered.contains("declined") || lowered.contains("card_declined") || lowered.contains("insufficient_funds") {
                kind = .cardDeclined
            } else if lowered.contains("network") || lowered.contains("timeout") || lowered.contains("offline") {
                kind = .networkError
            } else if lowered.contains("server") || lowered.contains("500") || lowered.contains("503") {
                kind = .serverError
            } else {
                kind = .checkoutError
            }
            onComplete(.failure(PaymentSheetError.paymentFailed(PaymentFailureDetail(kind: kind, message: message))))
        }
    }

    private func verifyAndComplete(transactionId: String) async {
        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            dismiss()
            onComplete(.failure(PaymentSheetError.notConfigured))
            return
        }

        let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
        do {
            let transaction = try await backend.verifyTransaction(transactionId: transactionId)
            dismiss()
            onComplete(.success(transaction))
            // Fire delegate for consistency across all checkout types
            await ZeroSettle.shared.delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
        } catch {
            dismiss()
            onComplete(.failure(PaymentSheetError.verificationFailed(error.localizedDescription)))
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
                PaymentSheetTrace.logger.debug("⏱  [WebView \(level)] \(msg)")
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            PaymentSheetTrace.logger.debug("⏱  ● webView.didFinish: \(webView.url?.absoluteString ?? "?")")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            PaymentSheetTrace.logger.error("⏱  ● webView.didFail: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                PaymentSheetTrace.logger.debug("⏱  ● webView.navigate: \(url.absoluteString)")
                if isCallbackURL(url) {
                    PaymentSheetTrace.logger.info("⏱  ● webView.callbackURL intercepted: \(url.absoluteString)")
                    handleCallbackURL(url)
                    decisionHandler(.cancel)
                    return
                }
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

            if status == "success" || status == "processing" {
                onAction(.complete(transactionId: transactionId))
            } else {
                onAction(.cancelled)
            }
        }
    }
}

// MARK: - Payment Failure Detail

/// Structured detail for payment failures within the payment sheet.
/// Classifies JS-callback and verification errors into actionable kinds.
public struct PaymentFailureDetail: Sendable {
    /// The category of payment failure.
    public enum Kind: String, Sendable {
        /// The card was declined by the payment processor.
        case cardDeclined
        /// A network error prevented the payment from completing.
        case networkError
        /// The server returned a non-2xx response.
        case serverError
        /// An error occurred during the checkout flow (JS callback).
        case checkoutError
        /// An unclassified failure.
        case unknown
    }

    /// The category of failure.
    public let kind: Kind
    /// A human-readable message describing the failure.
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

// MARK: - Payment Sheet Error

/// Errors specific to the payment sheet UI.
///
/// - Note: Prefer catching ``ZSError`` instead for a unified error type.
///   `PaymentSheetError` cases map to `ZSError` as follows:
///   - `.cancelled` → ``ZSError/cancelled``
///   - `.notConfigured` → ``ZSError/notConfigured``
///   - `.paymentFailed` → ``ZSError/checkoutFailed(reason:)``
///   - `.verificationFailed` → ``ZSError/transactionVerificationFailed(_:)``
///   - `.preloadFailed` → ``ZSError/apiError(_:)``
///   - `.userIdRequired` → ``ZSError/userIdRequired(productId:)``
public enum PaymentSheetError: Error, LocalizedError {
    case cancelled
    case notConfigured
    case paymentFailed(PaymentFailureDetail)
    case verificationFailed(String)
    case preloadFailed(APIErrorDetail)
    case userIdRequired

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Payment was cancelled"
        case .notConfigured: return "ZeroSettle is not configured"
        case .paymentFailed(let detail): return detail.message
        case .verificationFailed(let message): return "Verification failed: \(message)"
        case .preloadFailed(let detail): return detail.errorDescription
        case .userIdRequired: return "A userId is required for subscriptions and non-consumable products."
        }
    }
}

// MARK: - SwiftUI View Modifier

/// Preloads the PaymentIntent AND the WebView before presenting the sheet.
/// The user sees a fully-rendered checkout the moment it slides up.
private struct ZSPaymentSheetModifier<Header: View>: ViewModifier {
    @Binding var isPresented: Bool
    let product: ZSProduct
    let userId: String?
    let dismissible: Bool
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
                    preloader.reset()
                }
            }
            .sheet(isPresented: $showSheet, onDismiss: {
                PaymentSheetTrace.logger.debug("⏱  ● sheet.dismissed (isPresented:)")
                isPresented = false
                // Keep preloadedURL/transactionId — they're cached and reusable.
                // Only reset the WebView (it was consumed by the sheet).
                preloader.reset()
            }) {
                if let url = preloadedURL {
                    ZSPaymentSheet(
                        product: product,
                        userId: userId,
                        dismissible: dismissible,
                        preloader: preloader,
                        checkoutURL: url,
                        transactionId: preloadedTransactionId,
                        header: header
                    ) { result in
                        PaymentSheetTrace.logger.info("⏱  ● sheet.result: \(String(describing: result))")
                        if case .success = result {
                            CheckoutCache.shared.invalidate(productId: product.id, userId: userId)
                            preloadedURL = nil
                            preloadedTransactionId = nil
                        }
                        onComplete(result)
                    }
                } else {
                    ZSPaymentSheet(
                        product: product,
                        userId: userId,
                        dismissible: dismissible,
                        header: header
                    ) { result in
                        PaymentSheetTrace.logger.info("⏱  ● sheet.result: \(String(describing: result))")
                        if case .success = result {
                            CheckoutCache.shared.invalidate(productId: product.id, userId: userId)
                        }
                        onComplete(result)
                    }
                }
            }
    }

    private func preloadAll() async {
        let checkoutType = ZeroSettle.shared.checkoutType

        // Safari / SafariVC — delegate to purchase() which opens the browser
        guard checkoutType == .webview else {
            do {
                let transaction = try await ZeroSettle.shared.purchase(
                    productId: product.id, userId: userId
                )
                onComplete(.success(transaction))
            } catch {
                onComplete(.failure(error))
            }
            isPresented = false
            return
        }

        // Webview path — preload PaymentIntent + WebView, then present sheet
        let trace = PaymentSheetTrace("preloadAll(isPresented:)")
        PaymentSheetTrace.current = trace

        guard let result = await ZSPaymentSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else { trace.finish(); return }
            trace.event("sheet.presented", metadata: ["preloaded": "false"])
            trace.finish()
            showSheet = true
            return
        }

        guard !Task.isCancelled else { trace.finish(); return }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        await preloader.loadAndWait(url: result.checkoutURL)

        guard !Task.isCancelled else { trace.finish(); return }
        trace.event("sheet.presented", metadata: ["preloaded": "true"])
        trace.finish()
        showSheet = true
    }
}

// MARK: - Item-Based Modifier

/// Presents the payment sheet driven by an optional `ZSProduct?` binding.
/// When `item` becomes non-nil the sheet presents; on dismiss it's set back to `nil`.
///
/// Unlike `ZSPaymentSheetModifier`, this modifier owns its own preloader directly
/// so the `@StateObject` survives across item nil/non-nil transitions. This means
/// the preloader object isn't recreated on each open, and cached PaymentIntent data
/// is preserved for instant re-opens.
private struct ZSPaymentSheetItemModifier<Header: View>: ViewModifier {
    @Binding var item: ZSProduct?
    let userId: String?
    let dismissible: Bool
    let header: () -> Header
    let onComplete: (Result<ZSTransaction, Error>) -> Void

    @StateObject private var preloader = CheckoutPreloader()
    @State private var showSheet = false
    @State private var preloadedURL: URL?
    @State private var preloadedTransactionId: String?
    @State private var presentedProduct: ZSProduct?

    func body(content: Content) -> some View {
        content
            .background(
                PreloaderHost(webView: preloader.webView)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            )
            .task(id: item?.id) {
                if let product = item {
                    presentedProduct = product
                    await preloadAll(product: product)
                }
            }
            .sheet(isPresented: $showSheet, onDismiss: {
                PaymentSheetTrace.logger.debug("⏱  ● sheet.dismissed (item:)")
                item = nil
                // Keep preloadedURL/transactionId — they're cached and reusable.
                // Only reset the WebView (it was consumed by the sheet).
                preloader.reset()
            }) {
                if let product = presentedProduct {
                    if let url = preloadedURL {
                        ZSPaymentSheet(
                            product: product,
                            userId: userId,
                            dismissible: dismissible,
                            preloader: preloader,
                            checkoutURL: url,
                            transactionId: preloadedTransactionId,
                            header: header
                        ) { result in
                            PaymentSheetTrace.logger.info("⏱  ● sheet.result: \(String(describing: result))")
                            if case .success = result {
                                CheckoutCache.shared.invalidate(productId: product.id, userId: userId)
                                preloadedURL = nil
                                preloadedTransactionId = nil
                            }
                            onComplete(result)
                        }
                    } else {
                        ZSPaymentSheet(
                            product: product,
                            userId: userId,
                            dismissible: dismissible,
                            header: header
                        ) { result in
                            PaymentSheetTrace.logger.info("⏱  ● sheet.result: \(String(describing: result))")
                            if case .success = result {
                                CheckoutCache.shared.invalidate(productId: product.id, userId: userId)
                            }
                            onComplete(result)
                        }
                    }
                }
            }
    }

    private func preloadAll(product: ZSProduct) async {
        let checkoutType = ZeroSettle.shared.checkoutType

        // Safari / SafariVC — delegate to purchase() which opens the browser
        guard checkoutType == .webview else {
            do {
                let transaction = try await ZeroSettle.shared.purchase(
                    productId: product.id, userId: userId
                )
                onComplete(.success(transaction))
            } catch {
                onComplete(.failure(error))
            }
            item = nil
            return
        }

        // Webview path — preload PaymentIntent + WebView, then present sheet
        let trace = PaymentSheetTrace("preloadAll(item:)")
        PaymentSheetTrace.current = trace

        guard let result = await ZSPaymentSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else { trace.finish(); return }
            trace.event("sheet.presented", metadata: ["preloaded": "false"])
            trace.finish()
            showSheet = true
            return
        }

        guard !Task.isCancelled else { trace.finish(); return }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        await preloader.loadAndWait(url: result.checkoutURL)

        guard !Task.isCancelled else { trace.finish(); return }
        trace.event("sheet.presented", metadata: ["preloaded": "true"])
        trace.finish()
        showSheet = true
    }
}

extension View {
    /// Presents a ZeroSettle payment sheet when `isPresented` is true.
    ///
    /// The PaymentIntent and WebView are preloaded before the sheet appears,
    /// so the checkout is ready for interaction the moment it slides up.
    public func zsPaymentSheet(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetModifier<EmptyView>(
            isPresented: isPresented,
            product: product,
            userId: userId,
            dismissible: dismissible,
            header: { EmptyView() },
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet with a custom header when `isPresented` is true.
    public func zsPaymentSheet<Header: View>(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetModifier(
            isPresented: isPresented,
            product: product,
            userId: userId,
            dismissible: dismissible,
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
        item: Binding<ZSProduct?>,
        userId: String? = nil,
        dismissible: Bool = true,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetItemModifier<EmptyView>(
            item: item,
            userId: userId,
            dismissible: dismissible,
            header: { EmptyView() },
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet with a custom header, driven by an optional product binding.
    public func zsPaymentSheet<Header: View>(
        item: Binding<ZSProduct?>,
        userId: String? = nil,
        dismissible: Bool = true,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) -> some View {
        modifier(ZSPaymentSheetItemModifier(
            item: item,
            userId: userId,
            dismissible: dismissible,
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
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        present(
            from: viewController,
            product: product,
            userId: userId,
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            header: { EmptyView() },
            onComplete: onComplete
        )
    }
}

extension ZSPaymentSheet {
    /// Present a ZeroSettle payment sheet with a custom header from a UIKit view controller.
    ///
    /// Uses a transparent overlay that presents `ZSPaymentSheet` via SwiftUI's
    /// `.sheet()` modifier, so `.presentationDetents` works correctly.
    @MainActor
    public static func present<H: View>(
        from viewController: UIViewController,
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: @escaping () -> H,
        onComplete: @escaping (Result<ZSTransaction, Error>) -> Void
    ) {
        let bridge = UIKitSheetBridge<H>(
            product: product,
            userId: userId,
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            header: header,
            onComplete: onComplete,
            onDismissed: {
                viewController.dismiss(animated: false)
            }
        )

        let hosting = UIHostingController(rootView: bridge)
        hosting.view.backgroundColor = .clear
        hosting.modalPresentationStyle = .overFullScreen
        viewController.present(hosting, animated: false)
    }
}

/// Transparent bridge that preloads the PaymentIntent and WebView, then
/// presents `ZSPaymentSheet` via SwiftUI's `.sheet()` so
/// `.presentationDetents` works correctly when called from UIKit.
///
/// Mirrors the preloading behavior of `ZSPaymentSheetModifier` so the
/// user sees a fully-rendered checkout the moment the sheet slides up.
private struct UIKitSheetBridge<SheetHeader: View>: View {
    let product: ZSProduct
    let userId: String?
    let dismissible: Bool
    let checkoutURL: URL?
    let transactionId: String?
    let header: () -> SheetHeader
    let onComplete: (Result<ZSTransaction, Error>) -> Void
    let onDismissed: () -> Void

    @StateObject private var preloader = CheckoutPreloader()
    @State private var showSheet = false
    @State private var preloadedURL: URL?
    @State private var preloadedTransactionId: String?

    var body: some View {
        Color.clear
            .background(
                PreloaderHost(webView: preloader.webView)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            )
            .task { await preloadAll() }
            .sheet(isPresented: $showSheet, onDismiss: onDismissed) {
                if let url = preloadedURL {
                    ZSPaymentSheet(
                        product: product,
                        userId: userId,
                        dismissible: dismissible,
                        preloader: preloader,
                        checkoutURL: url,
                        transactionId: preloadedTransactionId,
                        header: header
                    ) { result in
                        if case .success = result {
                            CheckoutCache.shared.invalidate(productId: product.id, userId: userId)
                            preloadedURL = nil
                            preloadedTransactionId = nil
                        }
                        onComplete(result)
                    }
                } else {
                    ZSPaymentSheet(
                        product: product,
                        userId: userId,
                        dismissible: dismissible,
                        checkoutURL: checkoutURL,
                        transactionId: transactionId,
                        header: header,
                        onComplete: onComplete
                    )
                }
            }
    }

    private func preloadAll() async {
        let checkoutType = ZeroSettle.shared.checkoutType

        // Safari / SafariVC — delegate to purchase() which opens the browser
        guard checkoutType == .webview else {
            do {
                let transaction = try await ZeroSettle.shared.purchase(
                    productId: product.id, userId: userId
                )
                onComplete(.success(transaction))
            } catch {
                onComplete(.failure(error))
            }
            onDismissed()
            return
        }

        // Webview path — preload PaymentIntent + WebView, then present sheet
        if let checkoutURL {
            preloadedURL = checkoutURL
            preloadedTransactionId = transactionId
            await preloader.loadAndWait(url: checkoutURL)
            showSheet = true
            return
        }

        guard let result = await ZSPaymentSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            showSheet = true
            return
        }

        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId
        await preloader.loadAndWait(url: result.checkoutURL)
        showSheet = true
    }
}

// MARK: - Preview

#if DEBUG
struct ZSPaymentSheet_Previews: PreviewProvider {
    static var previews: some View {
        ZSPaymentSheet(
            product: ZSProduct(
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
