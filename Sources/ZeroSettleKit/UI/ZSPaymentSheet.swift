//
//  CheckoutSheet.swift
//  ZeroSettleKit
//
//  An embedded payment sheet that loads the ZeroSettle checkout page
//  in a WKWebView. The WebView is preloaded off-screen before the
//  sheet appears, so the user sees a fully-rendered checkout instantly.
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Shared JS & Helpers

/// Defines `window.__zsMeasure()` — drills past full-viewport wrappers
/// to find the bottom of the actual content elements.
private let setupMeasureJS = """
(function() {
    if (window.__zsMeasure) return;
    window.__zsMeasure = function() {
        var scrollY = window.scrollY || window.pageYOffset || 0;
        var el = document.getElementById('checkout-content');
        if (el) {
            var rect = el.getBoundingClientRect();
            return rect.top + scrollY + rect.height;
        }
        var viewH = window.innerHeight;
        var nodes = document.body.children;
        // Drill past single-visible-child wrappers that fill the viewport
        while (true) {
            var visible = [];
            for (var i = 0; i < nodes.length; i++) {
                if (nodes[i].offsetHeight > 0) visible.push(nodes[i]);
            }
            if (visible.length === 1 && visible[0].offsetHeight >= viewH * 0.9) {
                nodes = visible[0].children;
            } else {
                break;
            }
        }
        var maxBottom = 0;
        for (var i = 0; i < nodes.length; i++) {
            if (nodes[i].offsetHeight > 0) {
                var r = nodes[i].getBoundingClientRect();
                var bottom = r.bottom + scrollY;
                if (bottom > maxBottom) maxBottom = bottom;
            }
        }
        return maxBottom > 0 ? maxBottom : 400;
    };
})();
"""

/// One-shot measurement. Evaluate `setupMeasureJS` first.
private let measureContentJS = "window.__zsMeasure()"

/// Installs height tracking that continuously reports content height to native.
/// Uses ResizeObserver on `#checkout-content` + polling fallback for CSS transitions.
/// Fires immediately on install. Evaluate `setupMeasureJS` first.
private let heightObserverJS = """
(function() {
    if (window.__zsHeightObserver) return;
    var lastHeight = 0;
    function measureAndReport() {
        var height = window.__zsMeasure();
        if (height > 0 && Math.abs(height - lastHeight) > 1) {
            lastHeight = height;
            window.webkit.messageHandlers.checkoutComplete.postMessage({
                action: 'contentHeight',
                height: height
            });
        }
    }
    var target = document.getElementById('checkout-content') || document.body;
    var ro = new ResizeObserver(function() { measureAndReport(); });
    ro.observe(target);
    // Poll as fallback — ResizeObserver can miss CSS grid transitions in WKWebView
    setInterval(measureAndReport, 200);
    window.__zsHeightObserver = ro;
    measureAndReport();
})();
"""

/// Parses a JS evaluation result into a CGFloat (handles both CGFloat and NSNumber).
private func parseJSHeight(_ result: Any?) -> CGFloat? {
    if let height = result as? CGFloat, height > 0 {
        return height
    } else if let number = result as? NSNumber, number.doubleValue > 0 {
        return CGFloat(number.doubleValue)
    }
    return nil
}

// MARK: - Message Router

/// Proxy WKScriptMessageHandler that forwards messages to a mutable closure.
/// Lets us redirect WebView messages between preloader and sheet phases.
internal final class MessageRouter: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        onMessage?(message)
    }
}

// MARK: - WebKit Process Pool

/// Shared WebKit process pool and warm-up helper.
///
/// The first `WKWebView` in a process triggers GPU, WebContent, and Networking
/// subprocess launches, which can stall the main thread for 3-5 seconds.
/// Pre-warming with a throwaway `about:blank` load front-loads that cost
/// to when the checkout modifier enters the view hierarchy — well before
/// the user taps buy.
@MainActor
private enum WebKitWarmup {
    static let processPool = WKProcessPool()

    private static var isWarmed = false

    /// Launch WebKit's auxiliary processes by creating a throwaway WKWebView.
    /// Safe to call multiple times — only the first call does real work.
    static func warmIfNeeded() {
        guard !isWarmed else { return }
        isWarmed = true
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

/// Returns the StoreKit subscription end date if the given product matches
/// the active migration offer. Used to tell the backend to create a trial subscription.
@MainActor
private func migrationEndDate(for productId: String) -> Date? {
    guard let manager = ZeroSettle.shared.migrationManager,
          let offer = manager.offerData,
          offer.prompt.productId == productId else { return nil }
    return offer.storekitSubscriptionEnd
}

// MARK: - Checkout Preloader

/// Manages off-screen WKWebView creation and preloading.
/// Creates the WebView, loads the checkout URL, and waits for the
/// JavaScript "ready" signal before resolving.
@MainActor
internal final class CheckoutPreloader: ObservableObject {
    @Published var webView: WKWebView?
    @Published private(set) var isReady = false
    private(set) var measuredContentHeight: CGFloat = 0
    let messageRouter = MessageRouter()

    /// Each call to `loadAndWait` increments this token. Closures captured
    /// from a previous load cycle compare their token to detect staleness
    /// and avoid resuming a continuation that belongs to a newer cycle.
    private var loadToken: UInt = 0
    private var continuation: CheckedContinuation<Void, Never>?

    private var loadedURL: URL?

    @MainActor
    func loadAndWait(url: URL) async {
        // Reuse the existing WebView if it already loaded this URL
        if let wv = webView, isReady, loadedURL == url {
            return
        }

        // Cancel any in-flight load by resuming its continuation
        cancelCurrentLoad()

        loadToken &+= 1
        let myToken = loadToken

        let config = WKWebViewConfiguration()
        config.processPool = WebKitWarmup.processPool
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(messageRouter, name: "checkoutComplete")

        // Install height observer at document end — runs automatically when page loads.
        // This is more reliable than evaluateJavaScript after page load.
        let heightScript = WKUserScript(
            source: setupMeasureJS + "\n" + heightObserverJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(heightScript)

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 600), configuration: config)
        wv.scrollView.bounces = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear

        self.webView = wv

        let request = URLRequest(url: url)
        wv.load(request)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.continuation = cont

                messageRouter.onMessage = { [weak self] message in
                    guard let self = self, self.loadToken == myToken else { return }

                    guard message.name == "checkoutComplete",
                          let body = message.body as? [String: Any],
                          let action = body["action"] as? String else { return }

                    guard action == "ready" else { return }

                    self.webView?.evaluateJavaScript(setupMeasureJS + "\n" + measureContentJS) { [weak self] result, _ in
                        guard let self = self, self.loadToken == myToken else { return }
                        DispatchQueue.main.async {
                            if let height = parseJSHeight(result) {
                                self.measuredContentHeight = height
                            }
                            self.isReady = true
                            self.loadedURL = url
                            self.continuation?.resume()
                            self.continuation = nil
                        }
                    }
                }

                // Fallback: if the JS "ready" signal never fires (e.g. page error),
                // show the sheet anyway after 8 seconds rather than hanging forever.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard let self, self.loadToken == myToken, self.continuation != nil else { return }
                    ZSLogger.error("Preloader timed out waiting for JS ready signal — presenting sheet anyway", category: .checkout)
                    self.isReady = true
                    self.loadedURL = url
                    self.continuation?.resume()
                    self.continuation = nil
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.loadToken == myToken else { return }
                self.cancelCurrentLoad()
            }
        }
    }

    /// Resume and nil the current continuation (if any), clear WebView state.
    private func cancelCurrentLoad() {
        continuation?.resume()
        continuation = nil
        messageRouter.onMessage = nil
    }

    func reset() {
        cancelCurrentLoad()
        webView = nil
        isReady = false
        loadedURL = nil
        measuredContentHeight = 0
    }
}

// MARK: - Preloader Pool

/// Manages multiple off-screen WKWebViews, one per product.
/// All WebViews share a single WKProcessPool so the incremental cost is
/// ~3-7 MB per product (DOM + Stripe JS state), not a full subprocess.
///
/// Use `CheckoutPreloaderPool.shared` — the single instance is hosted in the
/// view hierarchy by `ZeroSettleHandlerModifier` (`.zeroSettleHandler()`).
@MainActor
internal final class CheckoutPreloaderPool: ObservableObject {
    static let shared = CheckoutPreloaderPool()

    private var preloaders: [String: CheckoutPreloader] = [:]

    /// All active WebViews — `PoolPreloaderHost` keeps these in the view hierarchy
    /// so WKWebView can load and render off-screen.
    @Published var webViews: [WKWebView] = []

    /// Returns the preloader for a product, creating one if needed.
    func preloader(for productId: String) -> CheckoutPreloader {
        if let existing = preloaders[productId] { return existing }
        let p = CheckoutPreloader()
        preloaders[productId] = p
        return p
    }

    /// Load checkout pages for all products in parallel.
    /// Each `loadAndWait` creates a WKWebView, starts loading, then suspends.
    /// WebKit processes the loads concurrently in the shared process pool.
    ///
    /// Respects `maxPreloadedWebViews` from the SDK configuration. When the limit
    /// is set, only the first N entries are loaded.
    func loadAll(entries: [(productId: String, url: URL)]) async {
        let limit = ZeroSettle.shared.currentConfig?.maxPreloadedWebViews
        let capped: [(productId: String, url: URL)]
        if let limit, limit > 0 {
            capped = Array(entries.prefix(limit))
            if entries.count > limit {
                ZSLogger.debug("[Pool] Capped WebView preloading to \(limit) (of \(entries.count) products)", category: .checkout)
            }
        } else {
            capped = entries
        }

        await withTaskGroup(of: Void.self) { group in
            for (productId, url) in capped {
                let p = preloader(for: productId)
                group.addTask { await p.loadAndWait(url: url) }
            }
        }
        refreshWebViews()
    }

    /// Populate the pool from cached PI responses for the given products.
    /// Only loads for checkout types that use inline WebViews (webView/nativePay).
    /// Skips entirely when `maxPreloadedWebViews` is 0.
    func loadFromCache(products: [ZSProduct], userId: String?) async {
        let checkoutType = ZeroSettle.shared.checkoutType
        guard checkoutType == .webView || checkoutType == .nativePay else { return }
        guard ZeroSettle.shared.currentConfig?.maxPreloadedWebViews != 0 else { return }

        let pk = ZeroSettle.shared.currentConfig?.publishableKey ?? ""
        var entries: [(productId: String, url: URL)] = []
        for product in products {
            if let result = await CheckoutResponseCache.shared.getURLAndTransactionId(
                productId: product.id, userId: userId, publishableKey: pk
            ) {
                entries.append((product.id, result.checkoutURL))
            }
        }
        guard !entries.isEmpty else { return }
        await loadAll(entries: entries)
    }

    /// Reset and remove the preloader for a specific product (e.g., after purchase).
    func reset(for productId: String) {
        preloaders[productId]?.reset()
        preloaders.removeValue(forKey: productId)
        refreshWebViews()
    }

    func resetAll() {
        preloaders.values.forEach { $0.reset() }
        preloaders.removeAll()
        refreshWebViews()
    }

    private func refreshWebViews() {
        webViews = preloaders.values.compactMap(\.webView)
    }
}

/// Invisible view that hosts multiple WKWebViews in the hierarchy.
internal struct PoolPreloaderHost: UIViewRepresentable {
    let webViews: [WKWebView]

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let current = Set(webViews.map { ObjectIdentifier($0) })
        for subview in uiView.subviews where !current.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }
        for wv in webViews where wv.superview == nil {
            wv.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
            uiView.addSubview(wv)
        }
    }
}

// MARK: - Payment Sheet Preload

/// Controls which products are preloaded when the `.checkoutSheet()` modifier
/// enters the view hierarchy.
///
/// Preloading creates a PaymentIntent ahead of time so the checkout URL is ready
/// the moment the user taps "buy". Attach to the modifier on a root-level view
/// for launch-time preloading.
///
/// ```swift
/// ContentView()
///     .checkoutSheet(isPresented: $show, product: product, userId: uid, preload: .all) { ... }
/// ```
public enum PaymentSheetPreload: Sendable {
    /// Preload all products from `ZeroSettle.shared.products`.
    case all
    /// Preload only the specified products.
    case specified([ZSProduct])
}

// MARK: - Payment Sheet

/// An embedded payment sheet for ZeroSettle web checkout.
///
/// Presents an optional native SwiftUI header above a WebView with
/// payment buttons. The WebView is preloaded before the sheet appears.
public struct CheckoutSheet<Header: View>: View {

    // MARK: - Configuration

    private let product: ZSProduct
    private let userId: String?
    private let freeTrialDays: Int
    private let dismissible: Bool
    private let prefetchedCheckoutURL: URL?
    private let prefetchedTransactionId: String?
    private let preloadedWebView: WKWebView?
    private let messageRouter: MessageRouter?
    private let initialContentHeight: CGFloat
    private let header: Header
    private let onComplete: (Result<CheckoutTransaction, Error>) -> Void

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    @State private var checkoutURL: URL?
    @State private var isLoading: Bool
    @State private var loadError: Error?
    @State private var transactionId: String?
    @State private var webContentHeight: CGFloat
    @State private var sheetHeight: CGFloat = 480

    /// Maximum WebView height — leave room for header, safe areas, and grab indicator.
    private var maxWebViewHeight: CGFloat {
        UIScreen.main.bounds.height - 180
    }

    // MARK: - Public Initialization (without preloading)

    public init(
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        self.product = product
        self.userId = userId
        self.freeTrialDays = freeTrialDays
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
    }

    // MARK: - Internal Initialization (with preloaded WebView)

    fileprivate init(
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        preloader: CheckoutPreloader,
        checkoutURL: URL,
        transactionId: String?,
        @ViewBuilder header: () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        self.product = product
        self.userId = userId
        self.freeTrialDays = freeTrialDays
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
    }
}

extension CheckoutSheet where Header == EmptyView {
    /// Creates a payment sheet without a native header — shows only payment buttons.
    public init(
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        self.init(
            product: product,
            userId: userId,
            freeTrialDays: freeTrialDays,
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            header: { EmptyView() },
            onComplete: onComplete
        )
    }

    /// Pre-create a PaymentIntent and cache the full response.
    /// Results are cached for 5 minutes so repeated opens skip the API call.
    /// Concurrent preloads for the same product are coalesced — only one
    /// server request is made, and all callers share the result.
    public static func preload(
        productId: String,
        userId: String? = nil,
        freeTrialDays: Int = 0
    ) async -> (checkoutURL: URL, transactionId: String)? {
        if let product = ZeroSettle.shared.product(for: productId), product.webPrice == nil {
            return nil
        }

        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            return nil
        }

        let pk = config.publishableKey

        let response = await CheckoutResponseCache.shared.fetchOrJoin(
            productId: productId, userId: userId, publishableKey: pk
        ) {
            let backend = Backend(baseURL: baseURL, publishableKey: pk)
            return try? await backend.initiateCheckout(
                productId: productId, userId: userId,
                freeTrialDays: freeTrialDays,
                storekitSubscriptionEnd: migrationEndDate(for: productId)
            )
        }

        guard let response, let url = URL(string: response.checkoutUrl) else {
            return nil
        }

        // Fire-and-forget prefetch to prime DNS, TLS, and URL cache
        if ZeroSettle.shared.checkoutType == .webView {
            Task.detached(priority: .utility) {
                _ = try? await URLSession.shared.data(from: url)
            }
        }

        return (url, response.transactionId)
    }

    /// Pre-caches the PaymentIntent for a single product so the sheet opens faster later.
    public static func warmUp(productId: String, userId: String? = nil, freeTrialDays: Int = 0) async {
        _ = await preload(productId: productId, userId: userId, freeTrialDays: freeTrialDays)
    }

    /// Pre-caches PaymentIntents for multiple products in parallel.
    ///
    /// Use this when you need to preload from a different view than where the
    /// `.checkoutSheet` modifier lives (e.g., at app launch for your top products).
    /// The `.checkoutSheet(preload: .all)` modifier handles this automatically for
    /// the full catalog.
    ///
    ///     .task {
    ///         let topProducts = products.prefix(10).map(\.id)
    ///         await CheckoutSheet.warmUp(productIds: topProducts, userId: "user_123")
    ///     }
    public static func warmUp(productIds: [String], userId: String? = nil, freeTrialDays: Int = 0) async {
        guard !productIds.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for productId in productIds {
                group.addTask {
                    _ = await preload(productId: productId, userId: userId, freeTrialDays: freeTrialDays)
                }
            }
        }
    }

    /// Pre-caches PaymentIntents for the entire product catalog in parallel,
    /// then pre-renders WKWebViews for instant checkout (webView/nativePay types only).
    ///
    /// Convenience for ``warmUp(productIds:userId:freeTrialDays:)`` with all products.
    public static func warmUpAll(userId: String? = nil, freeTrialDays: Int = 0) async {
        let products = await ZeroSettle.shared.products
        guard !products.isEmpty else { return }
        ZSLogger.info("[Checkout] Preloading \(products.count) product(s)", category: .checkout)
        await warmUp(productIds: products.map(\.id), userId: userId, freeTrialDays: freeTrialDays)
        await CheckoutPreloaderPool.shared.loadFromCache(products: products, userId: userId)
    }
}

extension CheckoutSheet {
    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            if let error = loadError {
                errorView(error)
            } else if let url = checkoutURL {
                if Header.self == EmptyView.self {
                    defaultHeader
                        .frame(minHeight: dismissible ? 60 : 0)
                } else {
                    header
                        .frame(maxWidth: .infinity, minHeight: dismissible ? 60 : 0)
                        .padding(.bottom, 8)
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
                .frame(height: webContentHeight > 0 ? min(webContentHeight, maxWebViewHeight) : 400)
            } else {
                ProgressView()
                    .frame(height: 400)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            guard newHeight > 0, newHeight != sheetHeight else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                sheetHeight = newHeight
            }
        }
        .overlay(alignment: .topTrailing) {
            if dismissible {
                Button {
                    dismiss()
                    onComplete(.failure(ZeroSettleError.cancelled))
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
        .presentationDetents([.height(sheetHeight)])
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
                ZSLogger.info("[Checkout] Cache miss for \(product.id) — calling initiateCheckout()", category: .checkout)
                await initiateCheckout()
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
                    await initiateCheckout()
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") {
                dismiss()
                onComplete(.failure(ZeroSettleError.cancelled))
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func initiateCheckout() async {
        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            await MainActor.run {
                loadError = PaymentSheetError.notConfigured
            }
            return
        }

        do {
            let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
            let checkout = try await backend.initiateCheckout(productId: product.id, userId: userId, freeTrialDays: freeTrialDays, storekitSubscriptionEnd: migrationEndDate(for: product.id))
            await MainActor.run {
                self.transactionId = checkout.transactionId
                self.checkoutURL = URL(string: checkout.checkoutUrl)
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

        case .complete(let txnId):
            Task {
                await verifyAndComplete(transactionId: txnId)
            }

        case .cancelled:
            dismiss()
            onComplete(.failure(ZeroSettleError.cancelled))

        case .error(let message):
            dismiss()
            let lowered = message.lowercased()
            if lowered.contains("cancel") {
                onComplete(.failure(ZeroSettleError.cancelled))
                return
            }
            let kind: PaymentFailureDetail.Kind
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
        // Dismiss immediately for responsive UX — verification continues in background.
        // The onComplete closure is captured by the Task and fires when ready.
        dismiss()

        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            onComplete(.failure(PaymentSheetError.notConfigured))
            return
        }

        let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
        do {
            let transaction = try await backend.verifyTransaction(transactionId: transactionId)
            onComplete(.success(transaction))
            // Fire delegate for consistency across all checkout types
            await ZeroSettle.shared.delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
        } catch {
            onComplete(.failure(PaymentSheetError.verificationFailed(error.localizedDescription)))
        }
    }
}

// MARK: - WebView Action

private enum WebViewAction {
    case ready
    case contentHeight(CGFloat)
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

            // Height observer was installed as a WKUserScript at document end,
            // so it's already running and polling every 200ms. It will route
            // contentHeight messages through the messageRouter → coordinator.

            return preloaded
        }

        // Standard path: create a new WebView
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WebKitWarmup.processPool
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

        // Install height observer at document end — runs automatically when page loads.
        let heightScript = WKUserScript(
            source: setupMeasureJS + "\n" + heightObserverJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(heightScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.webView = webView

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // For preloaded WebViews, JS timers may have been suspended while the
        // view was off-screen. Re-kick the observer now that the view is visible.
        // The idempotency guards in the JS make this safe to call multiple times.
        if preloadedWebView != nil && !context.coordinator.hasReinstalledObserver {
            context.coordinator.hasReinstalledObserver = true
            uiView.evaluateJavaScript(setupMeasureJS + "\n" + heightObserverJS, completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onAction: onAction)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var isLoading: Bool
        let onAction: (WebViewAction) -> Void
        weak var webView: WKWebView?
        private var hasCompleted = false
        var hasReinstalledObserver = false

        private let callbackHosts = CheckoutConstants.callbackHosts
        private let callbackPathPrefix = CheckoutConstants.callbackPathPrefix

        init(isLoading: Binding<Bool>, onAction: @escaping (WebViewAction) -> Void) {
            self._isLoading = isLoading
            self.onAction = onAction
        }

        // MARK: - JS Message Handler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "checkoutComplete",
                  let body = message.body as? [String: Any] else { return }

            let action = body["action"] as? String ?? ""

            switch action {
            case "ready":
                onAction(.ready)
                // Height observer was installed as a WKUserScript at document end,
                // so it's already running by the time "ready" fires.
                DispatchQueue.main.async {
                    self.isLoading = false
                }

            case "contentHeight":
                if let height = parseJSHeight(body["height"]) {
                    onAction(.contentHeight(height))
                }

            case "expandSheet", "collapseSheet":
                break // Height handled by ResizeObserver → contentHeight

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
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if isCallbackURL(url) {
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
internal struct PaymentFailureDetail: Sendable {
    /// The category of payment failure.
    internal enum Kind: String, Sendable {
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
    let kind: Kind
    /// A human-readable message describing the failure.
    let message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

// MARK: - Payment Sheet Error

/// Errors specific to the payment sheet UI.
///
/// - Note: Prefer catching ``ZeroSettleError`` instead for a unified error type.
///   `PaymentSheetError` cases map to `ZeroSettleError` as follows:
///   - `.cancelled` → ``ZeroSettleError/cancelled``
///   - `.notConfigured` → ``ZeroSettleError/notConfigured``
///   - `.paymentFailed` → ``ZeroSettleError/checkoutFailed(reason:)``
///   - `.verificationFailed` → ``ZeroSettleError/transactionVerificationFailed(_:)``
///   - `.preloadFailed` → ``ZeroSettleError/apiError(_:)``
///   - `.userIdRequired` → ``ZeroSettleError/userIdRequired(productId:)``
internal enum PaymentSheetError: Error, LocalizedError {
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

// MARK: - Active Window Scene Helper

/// Returns the foreground-active UIWindowScene for creating overlay windows.
/// Used by checkout modifiers to present via a dedicated UIWindow,
/// escaping any SwiftUI nested-sheet height constraints.
private func activeWindowScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
}

// MARK: - Window-Level Sheet Bridge

/// Lightweight bridge for the modifier path. Unlike `UIKitSheetBridge`, this:
/// - Accepts an external `CheckoutPreloader` from the shared pool
/// - Does NO preloading (modifier already preloaded)
/// - Presents the sheet immediately (`@State var showSheet = true`)
private struct WindowLevelSheetBridge<SheetHeader: View>: View {
    let product: ZSProduct
    let userId: String?
    let freeTrialDays: Int
    let dismissible: Bool
    let preloader: CheckoutPreloader
    let checkoutURL: URL?
    let transactionId: String?
    let header: () -> SheetHeader
    let onComplete: (Result<CheckoutTransaction, Error>) -> Void
    let onDismissed: () -> Void

    @State private var showSheet = true

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .sheet(isPresented: $showSheet, onDismiss: onDismissed) {
                if let url = checkoutURL {
                    CheckoutSheet(
                        product: product,
                        userId: userId,
                        freeTrialDays: freeTrialDays,
                        dismissible: dismissible,
                        preloader: preloader,
                        checkoutURL: url,
                        transactionId: transactionId,
                        header: header,
                        onComplete: onComplete
                    )
                } else {
                    CheckoutSheet(
                        product: product,
                        userId: userId,
                        freeTrialDays: freeTrialDays,
                        dismissible: dismissible,
                        header: header,
                        onComplete: onComplete
                    )
                }
            }
    }
}

// MARK: - SwiftUI View Modifier

/// Preloads the PaymentIntent AND the WebView before presenting the sheet.
/// The user sees a fully-rendered checkout the moment it slides up.
private struct CheckoutSheetModifier<Header: View>: ViewModifier {
    @Binding var isPresented: Bool
    let product: ZSProduct
    let userId: String?
    let freeTrialDays: Int
    let dismissible: Bool
    let preload: PaymentSheetPreload?
    let header: () -> Header
    let onComplete: (Result<CheckoutTransaction, Error>) -> Void

    private let pool = CheckoutPreloaderPool.shared
    @State private var showSheet = false
    @State private var preloadedURL: URL?
    @State private var preloadedTransactionId: String?
    @State private var overlayWindow: UIWindow?

    func body(content: Content) -> some View {
        content
            .task {
                WebKitWarmup.warmIfNeeded()
                if let preload {
                    await preloadProducts(preload)
                }
            }
            .task(id: isPresented) {
                if isPresented {
                    await preloadAll()
                } else {
                    showSheet = false
                }
            }
            .task(id: showSheet) {
                guard showSheet else { return }
                guard let scene = activeWindowScene() else {
                    showSheet = false
                    return
                }

                let preloader = pool.preloader(for: product.id)

                let bridge = WindowLevelSheetBridge(
                    product: product,
                    userId: userId,
                    freeTrialDays: freeTrialDays,
                    dismissible: dismissible,
                    preloader: preloader,
                    checkoutURL: preloadedURL,
                    transactionId: preloadedTransactionId,
                    header: header,
                    onComplete: { result in
                        if case .success = result {
                            Task {
                                await CheckoutResponseCache.shared.invalidate(
                                productId: product.id,
                                userId: userId,
                                publishableKey: ZeroSettle.shared.currentConfig?.publishableKey ?? ""
                            ) }
                            pool.reset(for: product.id)
                            preloadedURL = nil
                            preloadedTransactionId = nil
                        }
                        onComplete(result)
                    },
                    onDismissed: {
                        overlayWindow?.isHidden = true
                        overlayWindow = nil
                        isPresented = false
                        showSheet = false
                    }
                )

                let hosting = UIHostingController(rootView: bridge)
                hosting.view.backgroundColor = .clear

                let window = UIWindow(windowScene: scene)
                window.windowLevel = .normal + 1
                window.backgroundColor = .clear
                window.rootViewController = hosting
                window.makeKeyAndVisible()
                overlayWindow = window
            }
    }

    private func preloadAll() async {
        let checkoutType = ZeroSettle.shared.checkoutType

        // Safari / SafariVC — delegate to purchase() which opens the browser
        guard checkoutType == .webView else {
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
        guard let result = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId, freeTrialDays: freeTrialDays
        ) else {
            guard !Task.isCancelled else { return }
            showSheet = true
            return
        }

        guard !Task.isCancelled else { return }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        // Use shared pool — skip if warmUpAll() already rendered this product's WebView
        let preloader = pool.preloader(for: product.id)
        if !preloader.isReady {
            await preloader.loadAndWait(url: result.checkoutURL)
        }

        guard !Task.isCancelled else { return }
        showSheet = true
    }

    private func preloadProducts(_ preload: PaymentSheetPreload) async {
        let products: [ZSProduct]
        switch preload {
        case .all:
            products = await ZeroSettle.shared.products
        case .specified(let list):
            products = list
        }
        guard !products.isEmpty else { return }

        await CheckoutSheet<EmptyView>.warmUp(
            productIds: products.map(\.id), userId: userId, freeTrialDays: freeTrialDays
        )

        // Pre-render the bound product's WebView via the shared pool.
        guard !Task.isCancelled else { return }
        let checkoutType = ZeroSettle.shared.checkoutType
        guard checkoutType == .webView || checkoutType == .nativePay else { return }

        let pk = ZeroSettle.shared.currentConfig?.publishableKey ?? ""
        if let result = await CheckoutResponseCache.shared.getURLAndTransactionId(productId: product.id, userId: userId, publishableKey: pk) {
            preloadedURL = result.checkoutURL
            preloadedTransactionId = result.transactionId
            let preloader = pool.preloader(for: product.id)
            if !preloader.isReady {
                await preloader.loadAndWait(url: result.checkoutURL)
            }
        }
    }
}

// MARK: - Item-Based Modifier

/// Presents the payment sheet driven by an optional `ZSProduct?` binding.
/// When `item` becomes non-nil the sheet presents; on dismiss it's set back to `nil`.
private struct CheckoutSheetItemModifier<Header: View>: ViewModifier {
    @Binding var item: ZSProduct?
    let userId: String?
    let freeTrialDays: Int
    let dismissible: Bool
    let preload: PaymentSheetPreload?
    let header: () -> Header
    let onPresent: (() -> Void)?
    let onComplete: (Result<CheckoutTransaction, Error>) -> Void

    private let pool = CheckoutPreloaderPool.shared
    @State private var showSheet = false
    @State private var preloadedURL: URL?
    @State private var preloadedTransactionId: String?
    @State private var presentedProduct: ZSProduct?
    @State private var overlayWindow: UIWindow?

    func body(content: Content) -> some View {
        content
            .task {
                WebKitWarmup.warmIfNeeded()
                if let preload {
                    await preloadProducts(preload)
                }
            }
            .task(id: item?.id) {
                if let product = item {
                    presentedProduct = product
                    await preloadAll(product: product)
                }
            }
            .task(id: showSheet) {
                guard showSheet else { return }
                guard let product = presentedProduct else {
                    showSheet = false
                    return
                }
                guard let scene = activeWindowScene() else {
                    showSheet = false
                    return
                }

                onPresent?()

                let builtHeader = header()
                let preloader = pool.preloader(for: product.id)

                let bridge = WindowLevelSheetBridge(
                    product: product,
                    userId: userId,
                    freeTrialDays: freeTrialDays,
                    dismissible: dismissible,
                    preloader: preloader,
                    checkoutURL: preloadedURL,
                    transactionId: preloadedTransactionId,
                    header: { builtHeader },
                    onComplete: { result in
                        if case .success = result {
                            Task {
                                await CheckoutResponseCache.shared.invalidate(
                                productId: product.id,
                                userId: userId,
                                publishableKey: ZeroSettle.shared.currentConfig?.publishableKey ?? ""
                            ) }
                            pool.reset(for: product.id)
                            preloadedURL = nil
                            preloadedTransactionId = nil
                        }
                        onComplete(result)
                    },
                    onDismissed: {
                        overlayWindow?.isHidden = true
                        overlayWindow = nil
                        item = nil
                        showSheet = false
                    }
                )

                let hosting = UIHostingController(rootView: bridge)
                hosting.view.backgroundColor = .clear

                let window = UIWindow(windowScene: scene)
                window.windowLevel = .normal + 1
                window.backgroundColor = .clear
                window.rootViewController = hosting
                window.makeKeyAndVisible()
                overlayWindow = window
            }
    }

    private func preloadAll(product: ZSProduct) async {
        let checkoutType = ZeroSettle.shared.checkoutType

        // Safari / SafariVC — delegate to purchase() which opens the browser
        guard checkoutType == .webView else {
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

        guard let result = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId, freeTrialDays: freeTrialDays
        ) else {
            guard !Task.isCancelled else { return }
            showSheet = true
            return
        }

        guard !Task.isCancelled else { return }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        let preloader = pool.preloader(for: product.id)
        if !preloader.isReady {
            await preloader.loadAndWait(url: result.checkoutURL)
        }

        guard !Task.isCancelled else { return }
        showSheet = true
    }

    private func preloadProducts(_ preload: PaymentSheetPreload) async {
        let products: [ZSProduct]
        switch preload {
        case .all:
            products = await ZeroSettle.shared.products
        case .specified(let list):
            products = list
        }
        guard !products.isEmpty else { return }

        await CheckoutSheet<EmptyView>.warmUp(
            productIds: products.map(\.id), userId: userId, freeTrialDays: freeTrialDays
        )

        guard !Task.isCancelled, presentedProduct == nil else { return }
        await pool.loadFromCache(products: products, userId: userId)
    }
}

extension View {
    /// Presents a ZeroSettle payment sheet when `isPresented` is true.
    ///
    /// The PaymentIntent and WebView are preloaded before the sheet appears,
    /// so the checkout is ready for interaction the moment it slides up.
    ///
    /// - Parameter preload: Optional declarative preloading. When set, payment intents are
    ///   created as soon as the view enters the hierarchy (e.g. at app launch if on the root view).
    public func checkoutSheet(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int = 0,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetModifier<EmptyView>(
            isPresented: isPresented,
            product: product,
            userId: userId,
            freeTrialDays: freeTrialDays,
            dismissible: dismissible,
            preload: preload,
            header: { EmptyView() },
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet with a custom header when `isPresented` is true.
    ///
    /// - Parameter preload: Optional declarative preloading. When set, payment intents are
    ///   created as soon as the view enters the hierarchy.
    public func checkoutSheet<Header: View>(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int = 0,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetModifier(
            isPresented: isPresented,
            product: product,
            userId: userId,
            freeTrialDays: freeTrialDays,
            dismissible: dismissible,
            preload: preload,
            header: header,
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet driven by an optional product binding.
    ///
    /// When `item` is non-nil, the sheet presents for that product.
    /// On dismiss, `item` is automatically set back to `nil`.
    ///
    /// - Parameter preload: Optional declarative preloading. When set, payment intents are
    ///   created as soon as the view enters the hierarchy.
    ///
    ///     .checkoutSheet(item: $selectedProduct, userId: "user_123") { result in
    ///         print(result)
    ///     }
    public func checkoutSheet(
        item: Binding<ZSProduct?>,
        userId: String? = nil,
        freeTrialDays: Int = 0,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onPresent: (() -> Void)? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetItemModifier<EmptyView>(
            item: item,
            userId: userId,
            freeTrialDays: freeTrialDays,
            dismissible: dismissible,
            preload: preload,
            header: { EmptyView() },
            onPresent: onPresent,
            onComplete: onComplete
        ))
    }

    /// Presents a ZeroSettle payment sheet with a custom header, driven by an optional product binding.
    ///
    /// - Parameter preload: Optional declarative preloading. When set, payment intents are
    ///   created as soon as the view enters the hierarchy.
    /// - Parameter onPresent: Optional callback invoked just before the checkout sheet appears.
    ///   Use this to dismiss parent sheets or update UI state.
    public func checkoutSheet<Header: View>(
        item: Binding<ZSProduct?>,
        userId: String? = nil,
        freeTrialDays: Int = 0,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onPresent: (() -> Void)? = nil,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetItemModifier(
            item: item,
            userId: userId,
            freeTrialDays: freeTrialDays,
            dismissible: dismissible,
            preload: preload,
            header: header,
            onPresent: onPresent,
            onComplete: onComplete
        ))
    }
}

// MARK: - UIKit Presentation

extension CheckoutSheet where Header == EmptyView {
    /// Present a ZeroSettle payment sheet from a UIKit view controller.
    @MainActor
    public static func present(
        from viewController: UIViewController,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int = 0,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        present(
            from: viewController,
            product: product,
            userId: userId,
            freeTrialDays: freeTrialDays,
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            header: { EmptyView() },
            onComplete: onComplete
        )
    }
}

extension CheckoutSheet {
    /// Present a ZeroSettle payment sheet with a custom header from a UIKit view controller.
    ///
    /// Uses a transparent overlay that presents `CheckoutSheet` via SwiftUI's
    /// `.sheet()` modifier, so `.presentationDetents` works correctly.
    @MainActor
    public static func present<H: View>(
        from viewController: UIViewController,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int = 0,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: @escaping () -> H,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        let bridge = UIKitSheetBridge<H>(
            product: product,
            userId: userId,
            freeTrialDays: freeTrialDays,
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
/// presents `CheckoutSheet` via SwiftUI's `.sheet()` so
/// `.presentationDetents` works correctly when called from UIKit.
///
/// Mirrors the preloading behavior of `CheckoutSheetModifier` so the
/// user sees a fully-rendered checkout the moment the sheet slides up.
private struct UIKitSheetBridge<SheetHeader: View>: View {
    let product: ZSProduct
    let userId: String?
    let freeTrialDays: Int
    let dismissible: Bool
    let checkoutURL: URL?
    let transactionId: String?
    let header: () -> SheetHeader
    let onComplete: (Result<CheckoutTransaction, Error>) -> Void
    let onDismissed: () -> Void

    private let pool = CheckoutPreloaderPool.shared
    @State private var showSheet = false
    @State private var preloadedURL: URL?
    @State private var preloadedTransactionId: String?

    var body: some View {
        Color.clear
            .task { await preloadAll() }
            .sheet(isPresented: $showSheet, onDismiss: onDismissed) {
                if let url = preloadedURL {
                    CheckoutSheet(
                        product: product,
                        userId: userId,
                        freeTrialDays: freeTrialDays,
                        dismissible: dismissible,
                        preloader: pool.preloader(for: product.id),
                        checkoutURL: url,
                        transactionId: preloadedTransactionId,
                        header: header
                    ) { result in
                        if case .success = result {
                            Task { await CheckoutResponseCache.shared.invalidate(productId: product.id, userId: userId, publishableKey: ZeroSettle.shared.currentConfig?.publishableKey ?? "") }
                            pool.reset(for: product.id)
                            preloadedURL = nil
                            preloadedTransactionId = nil
                        }
                        onComplete(result)
                    }
                } else {
                    CheckoutSheet(
                        product: product,
                        userId: userId,
                        freeTrialDays: freeTrialDays,
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
        guard checkoutType == .webView else {
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

        // Webview path — use shared pool for pre-rendered WebView
        let url: URL
        if let checkoutURL {
            url = checkoutURL
            preloadedURL = checkoutURL
            preloadedTransactionId = transactionId
        } else if let result = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId, freeTrialDays: freeTrialDays
        ) {
            url = result.checkoutURL
            preloadedURL = result.checkoutURL
            preloadedTransactionId = result.transactionId
        } else {
            showSheet = true
            return
        }

        let preloader = pool.preloader(for: product.id)
        if !preloader.isReady {
            await preloader.loadAndWait(url: url)
        }
        showSheet = true
    }
}

// MARK: - Preview

#if DEBUG
struct CheckoutSheet_Previews: PreviewProvider {
    static var previews: some View {
        CheckoutSheet(
            product: ZSProduct(
                id: "premium_monthly",
                displayName: "Premium Monthly",
                productDescription: "Unlock all features",
                type: .autoRenewableSubscription,
                webPrice: Price(amountMicros: 4_990_000, currencyCode: "USD"),
                appStorePrice: Price(amountMicros: 5_990_000, currencyCode: "USD")
            ),
            userId: "user_123",
            freeTrialDays: 0
        ) { _ in }
    }
}
#endif
