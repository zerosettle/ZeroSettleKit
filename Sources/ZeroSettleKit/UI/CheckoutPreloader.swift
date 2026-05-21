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

/// Manages off-screen WKWebView creation and preloading for a single product.
///
/// ## Lifecycle & State Machine
///
/// A preloader progresses through these states:
///
/// ```
/// Created ──▶ Loading ──▶ Ready ──▶ ButtonsReady ──▶ Presented
///    │            │          │           │
///    │            │          ▼           ▼
///    │            │    ProcessDied   ProcessDied
///    │            │     (isAlive     (isAlive
///    │            │     = false)      = false)
///    ▼            ▼
///  reset()    cancelCurrentLoad()
/// ```
///
/// **Created**: `webView == nil`, `isReady == false`, `buttonsReady == false`.
///
/// **Loading**: `loadAndWait()` in progress. A fresh WKWebView has been created
/// and is loading the checkout URL off-screen. JS signals flow through the
/// `messageRouter`.
///
/// **Ready**: The JS `ready` signal fired — Stripe's payment element is rendered
/// and the DOM height has been measured. `isReady == true`, `isAlive == true`.
///
/// **ButtonsReady**: The JS `buttonsReady` signal fired — Apple Pay / card
/// buttons are visually rendered. `buttonsReady == true`. The checkout sheet
/// must NOT be presented until this state is reached.
///
/// **Presented**: The WebView has been transferred to the checkout sheet.
/// The `messageRouter.onMessage` closure is redirected to the sheet's
/// coordinator so JS messages (contentHeight, complete, error) flow to
/// the sheet instead of the preloader.
///
/// ## Flag Invalidation
///
/// All readiness flags (`isReady`, `buttonsReady`, `hasApplePay`) are reset:
/// - On every `loadAndWait()` call (creating a fresh WebView)
/// - On `reset()` (full cleanup after purchase or explicit reset)
/// - On `handleProcessTermination()` (WebContent process crashed)
///
/// This prevents stale flags from a dead WebView causing premature presentation.
///
/// ## Thread Safety
///
/// All properties and methods are `@MainActor`. Continuations are resumed
/// on the main queue. The `loadToken` prevents stale closures from a previous
/// load cycle from interfering with the current one.
@MainActor
internal final class CheckoutPreloader: ObservableObject {
    @Published var webView: WKWebView?
    @Published private(set) var isReady = false
    private(set) var buttonsReady = false
    private(set) var measuredContentHeight: CGFloat = 0
    let messageRouter = MessageRouter()
    var hasApplePay = false

    /// Returns true only if the WebView is loaded AND its content process is alive.
    /// A terminated WebContent process sets `webView.url` to nil, so this becomes
    /// false even though `isReady` may still be true.
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
    private var readyContinuation: CheckedContinuation<Void, Never>?

    private(set) var loadedURL: URL?
    private var navigationDelegate: PreloaderNavigationDelegate?

    @MainActor
    func loadAndWait(url: URL) async {
        let start = CFAbsoluteTimeGetCurrent()
        let shortURL = url.redactedForLogs

        // Reuse the existing WebView if it already loaded this URL
        if let wv = webView, isReady, loadedURL == url {
            if wv.url == nil {
                ZSLogger.info("[Preloader] loadAndWait: existing WebView url=nil (process died) — resetting. product=\(shortURL)", category: .checkout)
                reset()
            } else {
                ZSLogger.info("[Preloader] loadAndWait: reusing existing WebView (isReady=true, url valid). product=\(shortURL)", category: .checkout)
                return
            }
        }

        ZSLogger.info("[Preloader] loadAndWait: creating fresh WebView. product=\(shortURL) hadExisting=\(webView != nil) wasReady=\(isReady)", category: .checkout)

        // Cancel any in-flight load and reset readiness flags so they
        // reflect the NEW WebView, not the old (possibly dead) one.
        cancelCurrentLoad()
        isReady = false
        buttonsReady = false
        hasApplePay = false

        loadToken &+= 1
        let myToken = loadToken

        let config = WKWebViewConfiguration()
        config.processPool = WebKitWarmup.processPool
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(messageRouter, name: "checkoutComplete")
        config.userContentController.add(messageRouter, name: "openInSafari")
        config.userContentController.add(messageRouter, name: "consoleLog")

        // Wrap console.log/warn/error so JS diagnostics fired during preload
        // (e.g. the SDK's `[zs-checkout] sub-pe paymentMethodTypes=...`
        // breadcrumb at PE-create time) flow through to ZSLogger / Xcode.
        // Mirrors the same script in CheckoutSheet so the live and preload
        // paths capture identical signals.
        let consoleScript = WKUserScript(source: """
            (function() {
                function forward(level) {
                    var orig = console[level];
                    console[level] = function() {
                        var args = Array.prototype.slice.call(arguments).map(function(a) {
                            try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                            catch(e) { return String(a); }
                        });
                        try {
                            window.webkit.messageHandlers.consoleLog.postMessage({
                                level: level,
                                message: args.join(' ')
                            });
                        } catch (_) {}
                        orig.apply(console, arguments);
                    };
                }
                forward('log'); forward('warn'); forward('error');
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(consoleScript)

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

        let navDelegate = PreloaderNavigationDelegate()
        navDelegate.preloader = self
        wv.navigationDelegate = navDelegate
        self.navigationDelegate = navDelegate

        self.webView = wv

        CheckoutPreloaderPool.shared.refreshWebViews()
        let inWindow = wv.window != nil
        ZSLogger.info("[Preloader] loadAndWait: WebView created, addedToPool, inWindow=\(inWindow), pid=\(ProcessInfo.processInfo.processIdentifier). product=\(shortURL)", category: .checkout)

        let themedURL = applyThemeParam(to: url)
        wv.load(URLRequest(url: themedURL))
        ZSLogger.info("[Preloader] loadAndWait: URL load started. product=\(shortURL)", category: .checkout)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.continuation = cont

                messageRouter.onMessage = { [weak self] message in
                    guard let self = self, self.loadToken == myToken else { return }

                    // Forward JS console.* output to Xcode (filtered to
                    // SDK-prefixed diagnostics so Stripe's verbose chatter
                    // doesn't drown the log). Pairs with the consoleScript
                    // injected at userContentController setup above.
                    if message.name == "consoleLog",
                       let body = message.body as? [String: Any],
                       let text = body["message"] as? String,
                       text.hasPrefix("[zs-") {
                        let level = (body["level"] as? String) ?? "log"
                        let line = "[Preloader][JS \(level)] \(text)"
                        if level == "error" {
                            ZSLogger.error(line, category: .checkout)
                        } else {
                            ZSLogger.info(line, category: .checkout)
                        }
                        return
                    }

                    guard message.name == "checkoutComplete",
                          let body = message.body as? [String: Any],
                          let action = body["action"] as? String else { return }

                    if action == "buttonsReady" {
                        ZSLogger.info("[Preloader] JS signal: buttonsReady received at \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms. product=\(shortURL)", category: .checkout)
                        self.buttonsReady = true
                        self.buttonsReadyContinuation?.resume()
                        self.buttonsReadyContinuation = nil
                        return
                    }

                    if action == "apple_pay_detected" {
                        ZSLogger.info("[Preloader] JS signal: apple_pay_detected at \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms. product=\(shortURL)", category: .checkout)
                        self.hasApplePay = true
                        return
                    }

                    guard action == "ready" else {
                        ZSLogger.info("[Preloader] JS signal: action=\(action) at \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms. product=\(shortURL)", category: .checkout)
                        return
                    }

                    ZSLogger.info("[Preloader] JS signal: ready received at \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms — measuring height. product=\(shortURL)", category: .checkout)

                    self.webView?.evaluateJavaScript(setupMeasureJS + "\n" + measureContentJS) { [weak self] result, error in
                        guard let self = self, self.loadToken == myToken else { return }
                        DispatchQueue.main.async {
                            if let height = parseJSHeight(result) {
                                self.measuredContentHeight = height
                                ZSLogger.info("[Preloader] measured height=\(height) at \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms. product=\(shortURL)", category: .checkout)
                            } else {
                                ZSLogger.error("[Preloader] height measurement failed: result=\(String(describing: result)) error=\(String(describing: error)). product=\(shortURL)", category: .checkout)
                            }
                            self.isReady = true
                            self.loadedURL = url
                            self.readyContinuation?.resume()
                            self.readyContinuation = nil
                            self.continuation?.resume()
                            self.continuation = nil
                            ZSLogger.info("[Preloader] loadAndWait COMPLETE: isReady=true at \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms. product=\(shortURL)", category: .checkout)
                        }
                    }
                }

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard let self, self.loadToken == myToken, self.continuation != nil else { return }
                    let inWindow = self.webView?.window != nil
                    let urlAlive = self.webView?.url != nil
                    ZSLogger.error("[Preloader] TIMEOUT 8s — JS ready never fired. inWindow=\(inWindow) urlAlive=\(urlAlive) buttonsReady=\(self.buttonsReady). product=\(shortURL)", category: .checkout)
                    guard let wv = self.webView else {
                        self.isReady = true
                        self.loadedURL = url
                        self.readyContinuation?.resume()
                        self.readyContinuation = nil
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
                            self.readyContinuation?.resume()
                            self.readyContinuation = nil
                            self.continuation?.resume()
                            self.continuation = nil
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            ZSLogger.info("[Preloader] loadAndWait CANCELLED. product=\(shortURL)", category: .checkout)
            Task { @MainActor [weak self] in
                guard let self, self.loadToken == myToken else { return }
                self.cancelCurrentLoad()
            }
        }
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        ZSLogger.info("[Preloader] loadAndWait returned after \(elapsed)ms. isReady=\(isReady) buttonsReady=\(buttonsReady) hasApplePay=\(hasApplePay) height=\(measuredContentHeight). product=\(shortURL)", category: .checkout)
        webView?.evaluateJavaScript("window.__zsStopObserver && window.__zsStopObserver()", completionHandler: nil)
    }

    /// Waits until the `buttonsReady` signal fires from JavaScript, confirming
    /// payment buttons are visually rendered. Returns immediately if already ready.
    ///
    /// Returns `true` if buttons loaded, `false` if the 5-second timeout elapsed.
    @MainActor
    @discardableResult
    func waitForButtonsReady() async -> Bool {
        if buttonsReady { return true }

        let myToken = loadToken
        var timedOut = false

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.buttonsReadyContinuation = cont

            // Timeout: resume so the caller can handle the failure.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.loadToken == myToken, self.buttonsReadyContinuation != nil else { return }
                ZSLogger.info("[CheckoutPreloader] buttonsReady timeout — payment buttons never loaded", category: .checkout)
                timedOut = true
                self.buttonsReadyContinuation?.resume()
                self.buttonsReadyContinuation = nil
            }
        }
        return !timedOut
    }

    /// Waits until `isReady = true`, which is set AFTER `measureContentJS`
    /// completes and `measuredContentHeight` is populated. Returns immediately
    /// if already ready.
    ///
    /// This is distinct from `waitForButtonsReady()`:
    /// - `buttonsReady` fires as soon as Stripe payment buttons are interactive.
    /// - `isReady` fires later, after the DOM measurement round-trip lands.
    ///
    /// Callers that need a non-zero `measuredContentHeight` (e.g. so
    /// `CheckoutSheet`'s internal init seeds `webContentHeight` correctly and
    /// the sheet doesn't visibly shrink on first present) MUST wait for this,
    /// not just for `buttonsReady`.
    ///
    /// Returns `true` if ready, `false` if the 8-second timeout elapsed
    /// (matching the `loadAndWait` JS-ready timeout above).
    @MainActor
    @discardableResult
    func waitForReady() async -> Bool {
        if isReady { return true }

        let myToken = loadToken
        var timedOut = false

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.readyContinuation = cont

            // Timeout: resume so the caller can handle the failure.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.loadToken == myToken, self.readyContinuation != nil else { return }
                ZSLogger.error("[CheckoutPreloader] waitForReady timeout 8s — isReady never fired", category: .checkout)
                timedOut = true
                self.readyContinuation?.resume()
                self.readyContinuation = nil
            }
        }
        return !timedOut
    }

    /// Low-level cleanup: resumes any waiting continuations and clears the
    /// message handler. Does NOT touch the WebView or readiness flags —
    /// use `reset()` for full teardown.
    private func cancelCurrentLoad() {
        continuation?.resume()
        continuation = nil
        buttonsReadyContinuation?.resume()
        buttonsReadyContinuation = nil
        readyContinuation?.resume()
        readyContinuation = nil
        messageRouter.onMessage = nil
    }

    /// Full teardown: destroys the WebView and resets all readiness flags.
    /// Called after a successful purchase (to force a fresh PI on next open)
    /// or when explicitly discarding a dead WebView.
    func reset() {
        let url = loadedURL?.redactedForLogs ?? "none"
        let urlAlive = webView?.url != nil
        ZSLogger.info("[Preloader] reset() called. wasReady=\(isReady) hadWebView=\(webView != nil) urlWasAlive=\(urlAlive) product=\(url)", category: .checkout)
        cancelCurrentLoad()
        webView?.navigationDelegate = nil
        webView = nil
        isReady = false
        buttonsReady = false
        hasApplePay = false
        loadedURL = nil
        measuredContentHeight = 0
    }

    /// Called by `PreloaderNavigationDelegate` when the WebContent process
    /// crashes. Marks the preloader as not ready so `isAlive` returns false
    /// and `ensureReady()` will create a fresh WebView on next use.
    ///
    /// Does NOT nil the WebView — keeps it for debugging. The `isAlive` check
    /// (`wv.url != nil`) already returns false for a terminated process.
    func handleProcessTermination() {
        let url = loadedURL?.redactedForLogs ?? "unknown"
        let webViewURLNow = webView?.url?.redactedForLogs ?? "nil"
        ZSLogger.error("[Preloader] PROCESS TERMINATED. wasReady=\(isReady) buttonsReady=\(buttonsReady) webView.url=\(webViewURLNow) product=\(url)", category: .checkout)
        isReady = false
        buttonsReady = false
    }
}

// MARK: - Preloader Navigation Delegate

/// Detects WebContent process crashes for preloaded WebViews.
internal class PreloaderNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var preloader: CheckoutPreloader?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ZSLogger.error("[PreloaderDelegate] webViewWebContentProcessDidTerminate called. webView.url=\(webView.url?.redactedForLogs ?? "nil")", category: .checkout)
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
    /// Logged for lifecycle tracing.
    func reset(for productId: String) {
        ZSLogger.info("[Pool] reset(for: \(productId)) — preloader existed=\(preloaders[productId] != nil)", category: .checkout)
        preloaders[productId]?.reset()
        preloaders.removeValue(forKey: productId)
        refreshWebViews()
    }

    func resetAll() {
        ZSLogger.info("[Pool] resetAll() — clearing \(preloaders.count) preloader(s)", category: .checkout)
        preloaders.values.forEach { $0.reset() }
        preloaders.removeAll()
        refreshWebViews()
    }

    func refreshWebViews() {
        webViews = preloaders.values.compactMap(\.webView)
        ZSLogger.info("[Pool] refreshWebViews: \(webViews.count) live WebView(s) in pool", category: .checkout)
    }

    // MARK: - WebView Readiness

    /// Ensures the WebView for a product is loaded with payment buttons visible
    /// AND the DOM content height has been measured.
    ///
    /// This is the **single entry point** for getting a WebView ready to present.
    /// It encapsulates the full readiness sequence:
    ///
    /// 1. If the WebView process is dead (`!isAlive`), reset and create a fresh one
    /// 2. Load the checkout URL and wait for the Stripe `ready` signal
    /// 3. Wait for the `buttonsReady` signal (Apple Pay / card buttons rendered)
    /// 4. Wait for `isReady` (measureContentJS completed → `measuredContentHeight` set)
    ///
    /// Step 4 matters because `CheckoutSheet`'s internal init reads
    /// `preloader.measuredContentHeight` to seed its WebView frame height. If we
    /// returned at step 3 (the pre-1.3.6 behavior), the init would observe
    /// `measuredContentHeight == 0`, fall back to a hardcoded 300pt placeholder,
    /// and the live geometry observer would later report the real (typically
    /// smaller) height — causing the sheet to visibly shrink mid-presentation
    /// on the UIKit static `CheckoutSheet.present(...)` path (used by Flutter).
    ///
    /// All three checkout modifier variants (`CheckoutSheetModifier`,
    /// `CheckoutSheetItemModifier`, `UIKitSheetBridge`) must call this instead
    /// of manually checking preloader flags. This prevents divergence where one
    /// modifier gets a fix but others don't.
    ///
    /// - Parameters:
    ///   - productId: Product identifier to look up the preloader.
    ///   - url: Checkout URL to load if the WebView needs (re)loading.
    /// - Returns: `true` if the WebView is ready to present (buttons visible
    ///   AND content height measured), `false` if either signal timed out or
    ///   the task was cancelled.
    @MainActor
    func ensureReady(for productId: String, url: URL) async -> Bool {
        let preloader = preloader(for: productId)

        // Always route through loadAndWait — it is idempotent and URL-aware:
        // it reuses an alive WebView already loaded for THIS exact `url`, and
        // otherwise (a different checkout URL, or a dead content process)
        // discards it and loads fresh. Gating this on `isAlive` was a staleness
        // bug — `isAlive` (webView != nil && isReady && url != nil) never
        // compares URLs, so a preloader left ready for a *previous* checkout
        // short-circuited the gate and the sheet presented against a stale
        // WebView: a wrong/old PaymentIntent and a premature content height,
        // which the live sheet then cold-reloads and visibly resizes.
        await preloader.loadAndWait(url: url)

        if !preloader.buttonsReady {
            let ok = await preloader.waitForButtonsReady()
            if !ok {
                ZSLogger.error("[BUTTONS] ensureReady returning false — buttonsReady timed out for \(productId). isAlive=\(preloader.isAlive) isReady=\(preloader.isReady) measuredHeight=\(preloader.measuredContentHeight)", category: .checkout)
                return false
            }
        }

        // Also wait for measureContentJS to complete (sets measuredContentHeight
        // alongside isReady). Without this, CheckoutSheet's internal init reads
        // measuredContentHeight=0, the WebView falls back to a 300pt placeholder
        // frame, then the geometry observer later reports the real height and
        // the sheet visibly shrinks during presentation.
        if !preloader.isReady {
            let isReadyOk = await preloader.waitForReady()
            ZSLogger.error("[BUTTONS] ensureReady returning \(isReadyOk) — buttonsReady=\(preloader.buttonsReady) isReady=\(preloader.isReady) measuredHeight=\(preloader.measuredContentHeight) inWindow=\(preloader.webView?.window != nil) for \(productId)", category: .checkout)
            return isReadyOk
        }

        ZSLogger.error("[BUTTONS] ensureReady returning true — buttonsReady=\(preloader.buttonsReady) isReady=\(preloader.isReady) measuredHeight=\(preloader.measuredContentHeight) inWindow=\(preloader.webView?.window != nil) for \(productId)", category: .checkout)
        return true
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
