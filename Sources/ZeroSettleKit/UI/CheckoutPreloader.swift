//
//  CheckoutPreloader.swift
//  ZeroSettleKit
//
//  Off-screen WKWebView preloading infrastructure.
//  Manages WebView creation, process pool warm-up, preloader pooling,
//  and presentation coordination for the checkout sheet.
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

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
internal enum WebKitWarmup {
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

// MARK: - Checkout Preloader

/// Manages off-screen WKWebView creation and preloading.
/// Creates the WebView, loads the checkout URL, and waits for the
/// JavaScript "ready" signal before resolving.
@MainActor
internal final class CheckoutPreloader: ObservableObject {
    @Published var webView: WKWebView?
    @Published private(set) var isReady = false
    private(set) var buttonsReady = false
    private(set) var measuredContentHeight: CGFloat = 0
    let messageRouter = MessageRouter()
    var hasApplePay = false

    /// Returns true only if the WebView is loaded AND its content process is alive.
    /// A terminated WebContent process sets `webView.url` to nil.
    var isAlive: Bool {
        guard let wv = webView, isReady else { return false }
        return wv.url != nil
    }

    /// Each call to `loadAndWait` increments this token. Closures captured
    /// from a previous load cycle compare their token to detect staleness
    /// and avoid resuming a continuation that belongs to a newer cycle.
    private var loadToken: UInt = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var buttonsReadyContinuation: CheckedContinuation<Void, Never>?

    private(set) var loadedURL: URL?
    private var navigationDelegate: PreloaderNavigationDelegate?

    @MainActor
    func loadAndWait(url: URL) async {
        // Reuse the existing WebView if it already loaded this URL
        if let wv = webView, isReady, loadedURL == url {
            if wv.url == nil {
                // Content process was terminated while orphaned — need full reload
                reset()
            } else {
                return
            }
        }

        // Cancel any in-flight load by resuming its continuation
        cancelCurrentLoad()

        loadToken &+= 1
        let myToken = loadToken

        let config = WKWebViewConfiguration()
        config.processPool = WebKitWarmup.processPool
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(messageRouter, name: "checkoutComplete")

        // Install height observer + button detection at document end — runs automatically when page loads.
        // This is more reliable than evaluateJavaScript after page load.
        let heightScript = WKUserScript(
            source: setupMeasureJS + "\n" + heightObserverJS + "\n" + buttonReadyJS,
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

        // Set up process crash detection
        let navDelegate = PreloaderNavigationDelegate()
        navDelegate.preloader = self
        wv.navigationDelegate = navDelegate
        self.navigationDelegate = navDelegate

        self.webView = wv

        // Add to PoolPreloaderHost immediately so the WebView is in a visible UIWindow.
        // Without this, WebKit treats the page as hidden (document.visibilityState='hidden'),
        // and Stripe's Payment Element never fires "ready" — causing an 8s timeout.
        CheckoutPreloaderPool.shared.refreshWebViews()

        let themedURL = applyThemeParam(to: url)
        wv.load(URLRequest(url: themedURL))

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.continuation = cont

                messageRouter.onMessage = { [weak self] message in
                    guard let self = self, self.loadToken == myToken else { return }

                    guard message.name == "checkoutComplete",
                          let body = message.body as? [String: Any],
                          let action = body["action"] as? String else { return }

                    if action == "buttonsReady" {
                        self.buttonsReady = true
                        self.buttonsReadyContinuation?.resume()
                        self.buttonsReadyContinuation = nil
                        return
                    }

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
                    let inWindow = self.webView?.window != nil
                    ZSLogger.error("Preloader timed out waiting for JS ready signal — presenting sheet anyway (inWindow=\(inWindow))", category: .checkout)
                    // Try to measure even on timeout — content may be partially rendered
                    guard let wv = self.webView else {
                        self.isReady = true
                        self.loadedURL = url
                        self.continuation?.resume()
                        self.continuation = nil
                        return
                    }
                    wv.evaluateJavaScript(setupMeasureJS + "\n" + measureContentJS) { [weak self] result, _ in
                        guard let self, self.loadToken == myToken else { return }
                        DispatchQueue.main.async {
                            if let height = parseJSHeight(result), height > 0 {
                                self.measuredContentHeight = height
                            }
                            self.isReady = true
                            self.loadedURL = url
                            self.continuation?.resume()
                            self.continuation = nil
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.loadToken == myToken else { return }
                self.cancelCurrentLoad()
            }
        }
        // Pause the height observer while the WebView sits idle in the pool.
        // It will be resumed when the sheet presents (PaymentWebView.updateUIView).
        webView?.evaluateJavaScript("window.__zsStopObserver && window.__zsStopObserver()", completionHandler: nil)
    }

    /// Waits until the `buttonsReady` signal fires from JavaScript, confirming
    /// payment buttons are visually rendered. Returns immediately if already ready.
    /// Includes a 5-second safety timeout to prevent indefinite hangs.
    @MainActor
    func waitForButtonsReady() async {
        if buttonsReady { return }

        let myToken = loadToken

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.buttonsReadyContinuation = cont

            // Safety timeout: present sheet after 5s even if buttonsReady never fires
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.loadToken == myToken, self.buttonsReadyContinuation != nil else { return }
                ZSLogger.info("[CheckoutPreloader] buttonsReady safety timeout — proceeding", category: .checkout)
                self.buttonsReady = true
                self.buttonsReadyContinuation?.resume()
                self.buttonsReadyContinuation = nil
            }
        }
    }

    /// Resume and nil the current continuation (if any), clear WebView state.
    private func cancelCurrentLoad() {
        continuation?.resume()
        continuation = nil
        buttonsReadyContinuation?.resume()
        buttonsReadyContinuation = nil
        messageRouter.onMessage = nil
    }

    func reset() {
        cancelCurrentLoad()
        webView?.navigationDelegate = nil
        webView = nil
        isReady = false
        buttonsReady = false
        hasApplePay = false
        loadedURL = nil
        measuredContentHeight = 0
    }

    /// Called by WKWebView when its content process terminates.
    /// Immediately marks the preloader as not ready so the fast path
    /// won't present a dead WebView.
    func handleProcessTermination() {
        ZSLogger.error("[Preloader] WebContent process terminated for \(loadedURL?.absoluteString.prefix(60) ?? "unknown")", category: .checkout)
        isReady = false
        buttonsReady = false
        // Don't nil the webView — WKWebView can reload after process termination.
        // The next loadAndWait call will detect url==nil and reset fully.
    }
}

// MARK: - Preloader Navigation Delegate

/// Detects WebContent process crashes for preloaded WebViews.
internal class PreloaderNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var preloader: CheckoutPreloader?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak preloader] in
            preloader?.handleProcessTermination()
        }
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
    /// Default cap when `maxPreloadedWebViews` is nil (not explicitly set).
    /// Keeps WebContent process count reasonable on memory-constrained devices.
    static let defaultMaxPreloadedWebViews = 3

    func loadAll(entries: [(productId: String, url: URL)]) async {
        let configuredLimit = ZeroSettle.shared.currentConfig?.maxPreloadedWebViews
        let limit = configuredLimit ?? Self.defaultMaxPreloadedWebViews
        let capped: [(productId: String, url: URL)]
        if limit > 0 {
            capped = Array(entries.prefix(limit))
            if entries.count > limit {
                ZSLogger.debug("[Pool] Capped WebView preloading to \(limit) (of \(entries.count) products)", category: .checkout)
            }
        } else {
            capped = entries // 0 handled by caller guard
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

    func refreshWebViews() {
        webViews = preloaders.values.compactMap(\.webView)
    }

    // MARK: - Debug: Active Modifier Tracking

    #if DEBUG
    private var activeModifierCount = 0

    func registerModifier() {
        activeModifierCount += 1
        if activeModifierCount > 1 {
            ZSLogger.error(
                "[Checkout] \(activeModifierCount) .checkoutSheet modifiers active simultaneously. " +
                "This can cause payment failures. Use a single .checkoutSheet higher in the view hierarchy.",
                category: .checkout
            )
        }
    }

    func unregisterModifier() {
        activeModifierCount = max(0, activeModifierCount - 1)
    }
    #endif
}

// MARK: - Presentation Coordinator

/// Prevents multiple checkout sheets from presenting simultaneously.
/// Each modifier must `acquire` before creating the overlay window and
/// `release` in its `onDismissed` closure.
@MainActor
internal final class CheckoutPresentationCoordinator {
    static let shared = CheckoutPresentationCoordinator()

    private(set) var isPresenting = false
    private var activeProductId: String?

    /// Attempt to acquire the presentation lock.
    /// Returns `true` if this caller should proceed, `false` if another checkout is active.
    func acquire(for productId: String) -> Bool {
        guard !isPresenting else {
            ZSLogger.error(
                "[Checkout] Blocked concurrent presentation for \(productId) — " +
                "another checkout is already active (product: \(activeProductId ?? "unknown"))",
                category: .checkout
            )
            return false
        }
        isPresenting = true
        activeProductId = productId
        return true
    }

    /// Release the presentation lock. Must be called on every dismiss path.
    func release() {
        isPresenting = false
        activeProductId = nil
    }
}

/// Invisible view that hosts multiple WKWebViews in the hierarchy.
internal struct PoolPreloaderHost: UIViewRepresentable {
    let webViews: [WKWebView]

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.accessibilityElementsHidden = true
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
