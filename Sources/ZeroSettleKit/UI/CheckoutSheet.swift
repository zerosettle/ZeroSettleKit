//
//  CheckoutSheet.swift
//  ZeroSettleKit
//
//  An embedded payment sheet that loads the ZeroSettle checkout page
//  in a WKWebView. The WebView is preloaded off-screen before the
//  sheet appears, so the user sees a fully-rendered checkout instantly.
//
//  ═══════════════════════════════════════════════════════════════════
//  HEIGHT MANAGEMENT — READ THIS BEFORE MODIFYING SHEET SIZING
//  ═══════════════════════════════════════════════════════════════════
//
//  The sheet height is driven by the WebView's measured content height.
//  This sounds simple, but three subsystems interact in non-obvious ways
//  that have caused regressions. Understand all three before changing anything.
//
//  1. MEASUREMENT PIPELINE
//     ─────────────────────
//     JS (`__zsMeasure()`) measures `#checkout-content`'s bounding rect.
//     A ResizeObserver + 200ms poll sends `contentHeight` messages to Swift
//     via `WKScriptMessageHandler`. The measured height flows:
//
//       JS __zsMeasure() → postMessage({action:'contentHeight', height:H})
//         → MessageRouter → Coordinator → handleWebViewAction(.contentHeight(H))
//           → @State webContentHeight = H
//             → .frame(height: webContentHeight) on the ZStack
//               → VStack re-measures → .onGeometryChange fires
//                 → @State sheetHeight updates → .presentationDetents re-evaluates
//
//     PITFALL: The JS fallback (`return maxBottom > 0 ? maxBottom : 0`)
//     returns 0 when `#checkout-content` isn't found (e.g. still display:none).
//     Previously this returned 400, which was silently trusted as a real measurement.
//
//  2. STRIPE IFRAME FEEDBACK LOOP
//     ────────────────────────────
//     When `webContentHeight` changes → the WebView's `.frame(height:)` changes
//     → the WKWebView viewport resizes → Stripe iframes re-layout and temporarily
//     inflate → `__zsMeasure()` reports a larger height → webContentHeight grows
//     → frame grows → viewport grows → Stripe re-layouts again...
//
//     This creates an oscillation: correct(178) → inflated(572) → settling(478)
//     → correct(178). Each step animates the sheet, causing visible bouncing.
//
//     SOLUTION: `settleDeadline` — for 0.8s after the first contentHeight is
//     accepted, height INCREASES are rejected. The correct height is always the
//     minimum (inflated values are always larger than real content). This breaks
//     the feedback loop. After the deadline, increases are accepted normally
//     for user interactions (card expand, error messages, etc.).
//
//  3. PRELOADER MEASUREMENT TIMING
//     ─────────────────────────────
//     The preloader measures content height right after the JS "ready" signal,
//     which fires after Stripe's `expressCheckoutElement.on('ready')`. However:
//
//     a) On FIRST load (Stripe.js not cached), the Stripe iframes haven't
//        settled their intrinsic heights yet → measurement is inflated (~600).
//     b) If `#checkout-content` is still `display:none` at measurement time,
//        `__zsMeasure()` falls through to the drill-through path and may
//        return 0 (the fallback).
//
//     SOLUTION: Trust the preloader measurement only if 0 < measured < 500.
//     Untrusted → isLoading=true, webContentHeight=0, wait for live observer.
//     Trusted → webContentHeight=measured, but still isLoading=true (the
//     overlay masks compositing delays and prevents visible height jumps
//     while the settle guard evaluates the first live measurements).
//     The overlay clears on the first accepted contentHeight.
//
//  4. ANIMATION GATING
//     ─────────────────
//     Two flags gate animation of sheet height changes:
//
//     - `hasInitialHeight`: Set to true on the first geometry change that occurs
//       AFTER isLoading becomes false. All geometry changes before this are instant
//       (no animation). This prevents the sheet's initial layout pass from animating.
//
//     - `isLoading`: While true, geometry changes are always instant AND
//       hasInitialHeight is not set. This keeps the sheet in "instant mode" until
//       content is actually visible.
//
//     Together, these ensure: initial layout → instant, content appear → instant,
//     subsequent user-triggered changes (card expand/collapse) → animated.
//
//  TESTING CHECKLIST (after any height-related change):
//  □ First tap after entering store — no visible resize/bounce
//  □ Subsequent taps — content appears instantly, correct size
//  □ Back out of store, re-enter, first tap — still no bounce
//  □ Expand card form — smooth animated grow
//  □ Collapse card form — smooth animated shrink
//  □ Different products (consumable, subscription with trial) — correct sizes
//  □ Slow network / first Stripe load — loading overlay, then correct size
//  ═══════════════════════════════════════════════════════════════════
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Shared JS & Helpers

/// Defines `window.__zsMeasure()` — measures checkout content height for native sheet sizing.
///
/// Primary path: reads `#checkout-content` bounding rect (the container in native-checkout.html).
/// Fallback path: drills past full-viewport wrapper divs to find actual content bottom.
///
/// **IMPORTANT**: The fallback returns 0 (not a guessed value) when content can't be measured.
/// Returning a non-zero fallback (e.g. 400) caused the Swift side to trust it as a real
/// measurement, leading to incorrect initial sheet sizing. Zero signals "not ready yet" and
/// the Swift side falls back to `initialContentHeight` or the 300px default.
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
        // Return 0 when nothing measurable — never guess. See header comment.
        return maxBottom > 0 ? maxBottom : 0;
    };
})();
"""

/// One-shot measurement. Evaluate `setupMeasureJS` first.
private let measureContentJS = "window.__zsMeasure()"

/// Installs height tracking that continuously reports content height to native.
/// Uses ResizeObserver on `#checkout-content` + polling fallback for CSS transitions.
/// Fires immediately on install. Evaluate `setupMeasureJS` first.
///
/// **Re-report behavior**: Every 5th poll (~1s), the height is reported regardless
/// of whether it changed. This prevents the observer from going silent after the
/// Swift settle guard rejects a height — without periodic re-reports, the observer
/// would set `lastHeight` and never report again (same value = no change), leaving
/// `isLoading` stuck forever. The 1s interval ensures Swift gets another chance
/// after the 0.8s settle deadline expires.
private let heightObserverJS = """
(function() {
    if (window.__zsHeightObserver) return;
    var lastHeight = 0;
    var pollCount = 0;
    var intervalId = null;
    var target = document.getElementById('checkout-content') || document.body;
    var ro = new ResizeObserver(function() { measureAndReport(); });
    function measureAndReport() {
        var height = window.__zsMeasure();
        pollCount++;
        var delta = Math.abs(height - lastHeight);
        var isReReport = pollCount % 5 === 0;
        if (height > 0 && (delta > 1 || isReReport)) {
            lastHeight = height;
            window.webkit.messageHandlers.checkoutComplete.postMessage({
                action: 'contentHeight',
                height: height
            });
        }
    }
    window.__zsStartObserver = function() {
        ro.observe(target);
        if (!intervalId) intervalId = setInterval(measureAndReport, 200);
        measureAndReport();
    };
    window.__zsStopObserver = function() {
        ro.disconnect();
        if (intervalId) { clearInterval(intervalId); intervalId = null; }
    };
    window.__zsHeightObserver = ro;
    window.__zsStartObserver();
})();
"""

/// Detects when payment buttons (Apple Pay / Express Checkout, card accordion, or submit)
/// are visually rendered with non-zero dimensions. Fires a one-shot `buttonsReady` action
/// via `checkoutComplete` when any button passes the visibility check.
///
/// Uses a `MutationObserver` for immediate detection when Stripe hydrates, plus an
/// immediate check for elements already present (preloaded WebView case).
private let buttonReadyJS = """
(function() {
    if (window.__zsButtonReadySent) return;
    window.__zsButtonReadySent = false;

    function findAccordionButton(dataValue) {
        return document.querySelector('.p-AccordionButton[data-value="' + dataValue + '"]')
            || document.querySelector('[data-value="' + dataValue + '"]');
    }

    function checkButtonsReady(reason) {
        if (window.__zsButtonReadySent) return;

        // Check 1: Express Checkout / Apple Pay container with visible iframe
        var expressContainer = document.getElementById('express-checkout-container');
        if (expressContainer && expressContainer.classList.contains('visible')) {
            var iframe = expressContainer.querySelector('iframe');
            if (iframe && iframe.offsetHeight > 0 && iframe.offsetWidth > 0) {
                window.__zsButtonReadySent = true;
                try { window.webkit.messageHandlers.checkoutComplete.postMessage({ action: 'buttonsReady', reason: reason }); } catch (e) {}
                if (window.__zsButtonReadyObserver) { window.__zsButtonReadyObserver.disconnect(); }
                return;
            }
        }

        // Check 1b: Legacy Apple Pay container
        var applePayContainer = document.getElementById('apple-pay-container');
        if (applePayContainer && applePayContainer.classList.contains('visible')) {
            window.__zsButtonReadySent = true;
            try { window.webkit.messageHandlers.checkoutComplete.postMessage({ action: 'buttonsReady', reason: reason }); } catch (e) {}
            if (window.__zsButtonReadyObserver) { window.__zsButtonReadyObserver.disconnect(); }
            return;
        }

        // Check 2: Card accordion button visible
        var cardBtn = findAccordionButton('card');
        if (cardBtn && cardBtn.offsetHeight > 0 && cardBtn.offsetWidth > 0) {
            window.__zsButtonReadySent = true;
            try { window.webkit.messageHandlers.checkoutComplete.postMessage({ action: 'buttonsReady', reason: reason }); } catch (e) {}
            if (window.__zsButtonReadyObserver) { window.__zsButtonReadyObserver.disconnect(); }
            return;
        }

        // Check 3: Submit button visible (simple card-only layout)
        var submitBtn = document.querySelector('#submit, #submit-button, button[type="submit"]');
        if (submitBtn && submitBtn.offsetHeight > 0 && submitBtn.offsetWidth > 0) {
            window.__zsButtonReadySent = true;
            try { window.webkit.messageHandlers.checkoutComplete.postMessage({ action: 'buttonsReady', reason: reason }); } catch (e) {}
            if (window.__zsButtonReadyObserver) { window.__zsButtonReadyObserver.disconnect(); }
            return;
        }
    }

    // Immediate check for already-rendered elements (preloaded webview case)
    checkButtonsReady('immediate');

    // MutationObserver: fires when Stripe hydrates and paints payment buttons
    try {
        window.__zsButtonReadyObserver = new MutationObserver(function() {
            checkButtonsReady('dom-mutation');
        });
        window.__zsButtonReadyObserver.observe(document.body, {
            childList: true, subtree: true,
            attributes: true, attributeFilter: ['class']
        });
    } catch (e) {}
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

/// Appends `&dark=0` or `&dark=1` to a checkout URL based on the container background.
/// When a `containerBackground` is provided, its brightness determines the theme.
/// Otherwise falls back to the system appearance (light device → light checkout).
///
/// Note: the preloader bakes the theme at preload time using the system-appearance
/// fallback. If the user toggles dark mode between preload and presentation, the
/// preloaded WebView will use the stale theme. This is acceptable since the page
/// content is already rendered.
@MainActor
internal func applyThemeParam(to url: URL, containerBackground: UIColor? = nil) -> URL {
    let isDark: Bool
    if let bg = containerBackground {
        var brightness: CGFloat = 0
        if !bg.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil) {
            brightness = 0 // Unsupported color space — default to dark
        }
        isDark = brightness < 0.5
    } else if let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first {
        isDark = windowScene.traitCollection.userInterfaceStyle != .light
    } else {
        isDark = true
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url
    }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "dark" }
    items.append(URLQueryItem(name: "dark", value: isDark ? "1" : "0"))
    components.queryItems = items
    return components.url ?? url
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
    private(set) var buttonsReady = false
    private(set) var measuredContentHeight: CGFloat = 0
    let messageRouter = MessageRouter()

    /// Each call to `loadAndWait` increments this token. Closures captured
    /// from a previous load cycle compare their token to detect staleness
    /// and avoid resuming a continuation that belongs to a newer cycle.
    private var loadToken: UInt = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var buttonsReadyContinuation: CheckedContinuation<Void, Never>?

    private(set) var loadedURL: URL?

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
        webView = nil
        isReady = false
        buttonsReady = false
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
    private let dismissible: Bool
    private let prefetchedCheckoutURL: URL?
    private let prefetchedTransactionId: String?
    private let preloadedWebView: WKWebView?
    private let messageRouter: MessageRouter?
    private let initialContentHeight: CGFloat
    private let header: Header
    private let onComplete: (Result<CheckoutTransaction, Error>) -> Void

    // MARK: - State (see file header for height management documentation)

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var checkoutURL: URL?
    /// Gates animation and the inflation guard. While `true`, geometry changes are
    /// instant and heights ≥ 500 are rejected. Cleared on the first accepted
    /// `contentHeight`. Always starts `true` for preloaded views.
    @State private var isLoading: Bool
    @State private var loadError: Error?
    @State private var transactionId: String?
    /// The measured content height from the JS height observer. Drives the WebView
    /// frame via `.frame(height: webContentHeight)`. Changes to this value resize the
    /// WebView's viewport, which can trigger Stripe iframe re-layouts — see the
    /// "STRIPE IFRAME FEEDBACK LOOP" section in the file header.
    @State private var webContentHeight: CGFloat
    /// The sheet's presentation detent height. Updated by the geometry observer
    /// to match the VStack's measured height. Animation is gated by `hasInitialHeight`
    /// and `isLoading` — see "ANIMATION GATING" in the file header.
    @State private var sheetHeight: CGFloat = 480
    /// Set to `true` after the first geometry change where `isLoading` is false.
    /// All geometry changes before this point are applied instantly (no animation).
    @State private var hasInitialHeight = false
    /// The measured visible frame height of the ScrollView. Compared against
    /// `sheetHeight` (content height) to disable scrolling when content fits.
    @State private var scrollFrameHeight: CGFloat = 0
    /// Deadline until which height *increases* are rejected. Prevents the Stripe
    /// iframe feedback loop (see file header §2). Set in the preloaded init (0.8s
    /// from now) or on the first accepted contentHeight for non-preloaded views.
    /// After the deadline, all height changes are accepted for user interactions.
    @State private var settleDeadline: Date?
    /// Non-nil while the settle guard is bypassed for card expansion.
    /// Heights are animated and the settle guard won't re-arm until this expires.
    @State private var settleBypassExpiry: Date?

    // MARK: - Public Initialization (without preloading)

    public init(
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
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
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
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
        self.init(
            product: product,
            userId: userId,
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            header: header,
            onComplete: onComplete
        )
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
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        self.product = product
        self.userId = userId
        self.dismissible = dismissible
        self.prefetchedCheckoutURL = checkoutURL
        self.prefetchedTransactionId = transactionId
        self.preloadedWebView = preloader.webView
        self.messageRouter = preloader.messageRouter

        // Set checkoutURL/transactionId directly so the FIRST render shows the
        // WebView branch, not the ProgressView placeholder. Without this, the
        // first frame renders ProgressView (height=400), then .task sets the URL
        // and the second frame renders the WebView — causing an animated 400→342
        // sheet resize on every presentation.
        self._checkoutURL = State(initialValue: checkoutURL)
        self._transactionId = State(initialValue: transactionId)

        // Trust the preloader's measurement only when reasonable (0 < measured < 500).
        // Why 500: no real checkout content exceeds ~450px (Apple Pay + divider + card
        // option + security footer ≈ 178px; expanded card form ≈ 400px). Values ≥ 500
        // indicate the Stripe iframe hasn't settled (viewport-sized measurement).
        // Why > 0: the JS fallback returns 0 when #checkout-content isn't found.
        let measured = preloader.measuredContentHeight
        let trustworthy = measured > 0 && measured < 500
        self.initialContentHeight = trustworthy ? measured : 0
        self._webContentHeight = State(initialValue: trustworthy ? measured : 0)

        self._isLoading = State(initialValue: true)

        // Start the settling window to protect against the Stripe iframe feedback
        // loop (see file header §2). For trusted measurements, start immediately
        // since we already have a correct webContentHeight that could be inflated
        // by a live observer update. For untrusted, start on first accepted height.
        self._settleDeadline = State(initialValue: trustworthy ? Date().addingTimeInterval(0.8) : nil)

        self.header = header()
        self.onComplete = onComplete
    }
}

extension CheckoutSheet where Header == EmptyView {
    /// Creates a payment sheet without a native header — shows only payment buttons.
    public init(
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
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

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
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
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
            onComplete: onComplete
        )
    }

    /// Pre-create a PaymentIntent and cache the full response.
    /// Results are cached for 5 minutes so repeated opens skip the API call.
    /// Concurrent preloads for the same product are coalesced — only one
    /// server request is made, and all callers share the result.
    public static func preload(
        productId: String,
        userId: String? = nil
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

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public static func preload(
        productId: String,
        userId: String? = nil,
        freeTrialDays: Int
    ) async -> (checkoutURL: URL, transactionId: String)? {
        await preload(productId: productId, userId: userId)
    }

    /// Pre-caches the PaymentIntent for a single product so the sheet opens faster later.
    public static func warmUp(productId: String, userId: String? = nil) async {
        _ = await preload(productId: productId, userId: userId)
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public static func warmUp(productId: String, userId: String? = nil, freeTrialDays: Int) async {
        await warmUp(productId: productId, userId: userId)
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
    public static func warmUp(productIds: [String], userId: String? = nil) async {
        guard !productIds.isEmpty else { return }

        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            return
        }

        let pk = config.publishableKey

        // Build batch entries on MainActor to access shared state
        let entries: [BatchCheckoutRequest.ProductEntry] = await MainActor.run {
            var result: [BatchCheckoutRequest.ProductEntry] = []
            var groupOrigTxnIds: [Int: String?] = [:]

            for productId in productIds {
                guard let product = ZeroSettle.shared.product(for: productId),
                      product.webPrice != nil else { continue }

                let migEnd = migrationEndDate(for: productId)?.formatted(.iso8601)

                // Resolve originalTransactionId once per subscription group
                var origTxnId: String?
                if let groupId = product.subscriptionGroupId {
                    if let cached = groupOrigTxnIds[groupId] {
                        origTxnId = cached
                    } else {
                        let groupProductIds = Set(ZeroSettle.shared.products
                            .filter { $0.subscriptionGroupId == groupId }
                            .map { $0.id })
                        origTxnId = ZeroSettle.shared.entitlements
                            .first(where: {
                                $0.source == .storeKit &&
                                $0.isActive &&
                                $0.storekitOriginalTransactionId != nil &&
                                groupProductIds.contains($0.productId)
                            })?
                            .storekitOriginalTransactionId
                        groupOrigTxnIds[groupId] = origTxnId
                    }
                }

                result.append(BatchCheckoutRequest.ProductEntry(
                    productId: productId,
                    storekitSubscriptionEnd: migEnd,
                    storekitOriginalTransactionId: origTxnId
                ))
            }
            return result
        }

        guard !entries.isEmpty else { return }

        let backend = Backend(baseURL: baseURL, publishableKey: pk)

        guard let batchResponse = try? await backend.initiateCheckoutBatch(
            products: entries, userId: userId
        ) else {
            // Batch endpoint failed — fall back to individual preloads
            ZSLogger.info("[Checkout] Batch preload failed, falling back to individual", category: .checkout)
            await withTaskGroup(of: Void.self) { group in
                for productId in productIds {
                    group.addTask {
                        _ = await preload(productId: productId, userId: userId)
                    }
                }
            }
            return
        }

        // Populate cache with each successful result
        for result in batchResponse.results {
            if let response = result.asCheckoutResponse() {
                await CheckoutResponseCache.shared.set(
                    productId: result.productId,
                    userId: userId,
                    publishableKey: pk,
                    response: response
                )

                // Fire-and-forget DNS/TLS prefetch for webView mode
                if ZeroSettle.shared.checkoutType == .webView,
                   let url = URL(string: response.checkoutUrl) {
                    Task.detached(priority: .utility) {
                        _ = try? await URLSession.shared.data(from: url)
                    }
                }
            }
        }
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public static func warmUp(productIds: [String], userId: String? = nil, freeTrialDays: Int) async {
        await warmUp(productIds: productIds, userId: userId)
    }

    /// Pre-caches PaymentIntents for the entire product catalog in parallel,
    /// then pre-renders WKWebViews for instant checkout (webView/nativePay types only).
    ///
    /// Convenience for ``warmUp(productIds:userId:)`` with all products.
    public static func warmUpAll(userId: String? = nil) async {
        let products = await ZeroSettle.shared.products
        guard !products.isEmpty else { return }
        ZSLogger.info("[Checkout] Preloading \(products.count) product(s)", category: .checkout)
        await warmUp(productIds: products.map(\.id), userId: userId)
        await CheckoutPreloaderPool.shared.loadFromCache(products: products, userId: userId)
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public static func warmUpAll(userId: String? = nil, freeTrialDays: Int) async {
        await warmUpAll(userId: userId)
    }
}

extension CheckoutSheet {
    // MARK: - Body

    public var body: some View {
        ScrollView {
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

                    PaymentWebView(
                        url: url,
                        isLoading: $isLoading,
                        preloadedWebView: preloadedWebView,
                        messageRouter: messageRouter,
                        scrollEnabled: false,
                        containerBackground: colorScheme == .dark ? .black : .white,
                        onAction: handleWebViewAction
                    )
                    .accessibilityLabel("Payment form")
                    // WebView frame height. CAUTION: changing this resizes the WKWebView
                    // viewport, which triggers Stripe iframe re-layouts. The settle deadline
                    // protects against the resulting feedback loop (see file header §2).
                    .frame(height: {
                        if webContentHeight > 0 { return webContentHeight }
                        return initialContentHeight > 0 ? initialContentHeight : 300.0
                    }())
                } else {
                    ProgressView()
                        .accessibilityLabel("Loading payment form")
                        .frame(height: 400)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            // Geometry observer → sheetHeight → .presentationDetents.
            // Animation gating (see file header §4):
            //   isLoading=true  → always instant, don't set hasInitialHeight
            //   hasInitialHeight=false → instant (first real layout), then set flag
            //   both false → animated (user-triggered: card expand/collapse)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                guard newHeight > 0, newHeight != sheetHeight else { return }
                if hasInitialHeight && !isLoading {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        sheetHeight = newHeight
                    }
                } else {
                    sheetHeight = newHeight
                    if !isLoading {
                        hasInitialHeight = true
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(sheetHeight <= scrollFrameHeight)
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 20) }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            scrollFrameHeight = newHeight
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
                .accessibilityLabel("Close")
                .accessibilityHint("Dismisses the checkout sheet")
                .padding(.top, 14)
                .padding(.trailing, 18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .presentationDetents(sheetHeight > UIScreen.main.bounds.height * 0.55
            ? [.height(sheetHeight), .large]
            : [.height(sheetHeight)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .interactiveDismissDisabled(!dismissible)
        .onDisappear {
            // Pause the height observer while the WebView sits idle in the pool.
            // Prevents 200ms polling on a hidden WebView. Resumed in updateUIView
            // when the sheet presents again.
            preloadedWebView?.evaluateJavaScript("window.__zsStopObserver && window.__zsStopObserver()", completionHandler: nil)

            // Reset card form to collapsed state so the next present starts
            // clean. The WebView persists in the preloader pool — without this,
            // the expanded card DOM state carries over to the next sheet.
            preloadedWebView?.evaluateJavaScript("""
                if(typeof cardExpanded!=='undefined'&&cardExpanded){
                    var ce=document.getElementById('card-entry');
                    ce.style.transition='none';
                    ce.classList.remove('visible');
                    ce.offsetHeight;
                    ce.style.transition='';
                    document.getElementById('pay-button').classList.add('hidden');
                    document.getElementById('card-chevron').classList.remove('expanded');
                    cardExpanded=false;
                }
                """, completionHandler: nil)
        }
        .task {
            // Validate userId for subscription/non-consumable products
            if userId == nil {
                let type = product.type
                if type == .autoRenewableSubscription || type == .nonRenewingSubscription || type == .nonConsumable {
                    loadError = PaymentSheetError.userIdRequired
                    return
                }
            }

            // For preloaded views, checkoutURL and transactionId are set in init
            // (avoids a ProgressView flash on the first frame). Only fetch if missing.
            if checkoutURL == nil {
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
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Unable to load checkout")
                    .font(.headline)
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .accessibilityElement(children: .combine)
            Button("Try Again") {
                loadError = nil
                Task {
                    await initiateCheckout()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Retries loading the checkout form")
            Button("Cancel") {
                dismiss()
                onComplete(.failure(ZeroSettleError.cancelled))
            }
            .foregroundStyle(.secondary)
            .accessibilityHint("Dismisses the checkout sheet")
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
            let checkout = try await backend.initiateCheckout(productId: product.id, userId: userId, storekitSubscriptionEnd: migrationEndDate(for: product.id))
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

        case .expandSheet:
            // Clear the settle guard so CSS transition heights are accepted.
            // The 1s window covers the ~0.4s CSS transition plus Stripe settling.
            settleDeadline = nil
            settleBypassExpiry = Date().addingTimeInterval(1.0)

        case .contentHeight(let height):
            // ── Settle guard (file header §2) ──────────────────────────
            // During the 0.8s settling window, reject height INCREASES.
            // Stripe iframe re-layouts cause a feedback loop where the
            // measured height oscillates: correct → inflated → correct.
            // The correct height is always the minimum because inflated
            // values come from unsettled Stripe iframes filling the viewport.
            // After the deadline, increases are accepted normally (card expand).
            // ── Settle guard (file header §2) ──────────────────────────
            if let deadline = settleDeadline {
                if Date() < deadline {
                    if webContentHeight > 0 && height > webContentHeight {
                        return
                    }
                } else {
                    settleDeadline = nil
                }
            }

            // ── Inflation guard ────────────────────────────────────────
            if isLoading && height >= 500 {
                return
            }

            let bypassing = settleBypassExpiry.map { Date() < $0 } ?? false
            if bypassing {
                withAnimation(.easeInOut(duration: 0.35)) {
                    webContentHeight = height
                }
            } else {
                webContentHeight = height
                // Expire a stale bypass window.
                if settleBypassExpiry != nil { settleBypassExpiry = nil }
            }
            if height > 0 && isLoading {
                withAnimation(.easeOut(duration: 0.15)) {
                    isLoading = false
                }
            }

            // Start the settling window on the first accepted height
            // (non-preloaded path; preloaded views set this in init).
            // Skip re-arming during an active expand bypass — the CSS
            // transition sends increasing heights that would be rejected.
            if settleDeadline == nil && height > 0 && !bypassing {
                settleDeadline = Date().addingTimeInterval(0.8)
            }

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
    case expandSheet
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
    var scrollEnabled: Bool = true
    var containerBackground: UIColor?
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

        // Install height observer + button detection at document end — runs automatically when page loads.
        let heightScript = WKUserScript(
            source: setupMeasureJS + "\n" + heightObserverJS + "\n" + buttonReadyJS,
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

        let themedURL = applyThemeParam(to: url, containerBackground: containerBackground)
        webView.load(URLRequest(url: themedURL))

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // For preloaded WebViews, the height observer was paused while the
        // WebView sat idle in the pool. Resume it now that the sheet is visible.
        if preloadedWebView != nil && !context.coordinator.hasReinstalledObserver {
            context.coordinator.hasReinstalledObserver = true
            // Resume the observer and force an immediate measurement so the
            // sheet gets the correct height right away.
            uiView.evaluateJavaScript(
                "window.__zsStartObserver && window.__zsStartObserver();" +
                "if(window.__zsMeasure){var h=window.__zsMeasure();" +
                "if(h>0)window.webkit.messageHandlers.checkoutComplete.postMessage({action:'contentHeight',height:h});}"
            , completionHandler: nil)
        }

        // Only allow scrolling when content overflows the visible frame
        uiView.scrollView.isScrollEnabled = scrollEnabled
        uiView.scrollView.bounces = scrollEnabled
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

            case "expandSheet":
                onAction(.expandSheet)
            case "collapseSheet":
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
    case transactionFailed(status: String)
    case verificationTimedOut
    case verificationFailed(String)
    case preloadFailed(APIErrorDetail)
    case userIdRequired

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Payment was cancelled"
        case .notConfigured: return "ZeroSettle is not configured"
        case .paymentFailed(let detail): return detail.message
        case .transactionFailed(let status): return "Transaction failed with status: \(status)"
        case .verificationTimedOut: return "Transaction verification timed out"
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

// MARK: - Sheet Dismiss Detector (UIKit lifecycle)

/// Detects the START of a sheet dismiss animation via UIKit's `viewWillDisappear`,
/// which fires before the animation begins — unlike SwiftUI's `onDismiss` which fires after.
/// Place inside `.sheet()` content as a `.background` to get a callback when dismiss starts.
private struct SheetDismissDetector: UIViewControllerRepresentable {
    let onWillDismiss: () -> Void

    func makeUIViewController(context: Context) -> SheetDismissDetectorVC {
        SheetDismissDetectorVC(onWillDismiss: onWillDismiss)
    }
    func updateUIViewController(_ vc: SheetDismissDetectorVC, context: Context) {}
}

private class SheetDismissDetectorVC: UIViewController {
    let onWillDismiss: () -> Void
    private var hasAppeared = false

    init(onWillDismiss: @escaping () -> Void) {
        self.onWillDismiss = onWillDismiss
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = UIView()
        v.frame = .zero
        v.isUserInteractionEnabled = false
        view = v
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard hasAppeared else { return }
        // Only fire when the sheet itself is being dismissed
        var vc: UIViewController? = parent
        var depth = 0
        while let p = vc, depth < 10 {
            if p.isBeingDismissed { onWillDismiss(); return }
            vc = p.parent
            depth += 1
        }
    }
}

// MARK: - Window-Level Sheet Bridge

/// Lightweight bridge for the modifier path. Unlike `UIKitSheetBridge`, this:
/// - Accepts an external `CheckoutPreloader` from the shared pool
/// - Does NO preloading (modifier already preloaded)
/// - Presents the sheet immediately (`@State var showSheet = true`)
private struct WindowLevelSheetBridge<SheetHeader: View>: View {
    let product: ZSProduct
    let userId: String?
    let dismissible: Bool
    let preloader: CheckoutPreloader
    let checkoutURL: URL?
    let transactionId: String?
    let header: () -> SheetHeader
    let onComplete: (Result<CheckoutTransaction, Error>) -> Void
    let onDismissed: () -> Void

    @State private var showSheet = true
    @State private var scrimVisible = false

    var body: some View {
        Color.black.opacity(scrimVisible ? 0.6 : 0)
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.35), value: scrimVisible)
            .onAppear { scrimVisible = true }
            .sheet(isPresented: $showSheet, onDismiss: {
                onDismissed()
            }) {
                Group {
                    if let url = checkoutURL {
                        CheckoutSheet(
                            product: product,
                            userId: userId,
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
                            dismissible: dismissible,
                            header: header,
                            onComplete: onComplete
                        )
                    }
                }
                .background {
                    SheetDismissDetector {
                        withAnimation(.easeIn(duration: 0.3)) { scrimVisible = false }
                    }
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
            .onAppear {
                #if DEBUG
                if preload != nil { pool.registerModifier() }
                #endif
            }
            .onDisappear {
                #if DEBUG
                if preload != nil { pool.unregisterModifier() }
                #endif
            }
            .task {
                WebKitWarmup.warmIfNeeded()
                if let preload {
                    Task { @MainActor in
                        await preloadProducts(preload)
                    }
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

                guard CheckoutPresentationCoordinator.shared.acquire(for: product.id) else {
                    showSheet = false
                    isPresented = false
                    return
                }

                guard let scene = activeWindowScene() else {
                    CheckoutPresentationCoordinator.shared.release()
                    showSheet = false
                    return
                }

                let preloader = pool.preloader(for: product.id)

                let bridge = WindowLevelSheetBridge(
                    product: product,
                    userId: userId,
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
                        }
                        onComplete(result)
                    },
                    onDismissed: {
                        CheckoutPresentationCoordinator.shared.release()
                        // Always reset the preloader — stale Stripe JS state causes
                        // failures when a WebView is reused for a subsequent checkout.
                        pool.reset(for: product.id)
                        preloadedURL = nil
                        preloadedTransactionId = nil
                        // Delay teardown so the system's dismiss animation
                        // can finish before the overlay window disappears.
                        let window = overlayWindow
                        overlayWindow = nil
                        isPresented = false
                        showSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            window?.isHidden = true
                            // Refresh AFTER the overlay window is hidden so the
                            // WebView's old superview is gone and PoolPreloaderHost
                            // can re-adopt it into a visible UIWindow.
                            pool.refreshWebViews()
                        }
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
        guard checkoutType == .webView || checkoutType == .nativePay else {
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
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else { return }
            // Preload failed — don't present an empty sheet.
            onComplete(.failure(ZeroSettleError.checkoutFailed(reason: .other("Failed to create payment"))))
            isPresented = false
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

        // Wait for payment buttons to be visually rendered before presenting
        if !preloader.buttonsReady {
            await preloader.waitForButtonsReady()
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
            productIds: products.map(\.id), userId: userId
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
            .onAppear {
                #if DEBUG
                if preload != nil { pool.registerModifier() }
                #endif
            }
            .onDisappear {
                #if DEBUG
                if preload != nil { pool.unregisterModifier() }
                #endif
            }
            .task {
                WebKitWarmup.warmIfNeeded()
                if let preload {
                    Task { @MainActor in
                        await preloadProducts(preload)
                    }
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

                guard CheckoutPresentationCoordinator.shared.acquire(for: product.id) else {
                    showSheet = false
                    item = nil
                    return
                }

                guard let scene = activeWindowScene() else {
                    CheckoutPresentationCoordinator.shared.release()
                    showSheet = false
                    return
                }

                onPresent?()

                let builtHeader = header()
                let preloader = pool.preloader(for: product.id)

                let bridge = WindowLevelSheetBridge(
                    product: product,
                    userId: userId,
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
                        }
                        onComplete(result)
                    },
                    onDismissed: {
                        CheckoutPresentationCoordinator.shared.release()
                        // Always reset the preloader — stale Stripe JS state causes
                        // failures when a WebView is reused for a subsequent checkout.
                        pool.reset(for: product.id)
                        preloadedURL = nil
                        preloadedTransactionId = nil
                        let window = overlayWindow
                        overlayWindow = nil
                        item = nil
                        showSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            window?.isHidden = true
                            // Refresh AFTER the overlay window is hidden so the
                            // WebView's old superview is gone and PoolPreloaderHost
                            // can re-adopt it into a visible UIWindow.
                            pool.refreshWebViews()
                        }
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
        let jurisdiction = ZeroSettle.shared.detectedJurisdiction
        ZSLogger.info("[Checkout] preloadAll: product=\(product.id), checkoutType=\(checkoutType.rawValue), jurisdiction=\(jurisdiction.map { String(describing: $0) } ?? "nil"), isBootstrapped=\(ZeroSettle.shared.isBootstrapped)", category: .checkout)

        // Safari / SafariVC — delegate to purchase() which opens the browser
        guard checkoutType == .webView || checkoutType == .nativePay else {
            ZSLogger.info("[Checkout] preloadAll: routing to purchase() for \(checkoutType.rawValue)", category: .checkout)
            do {
                let transaction = try await ZeroSettle.shared.purchase(
                    productId: product.id, userId: userId
                )
                onComplete(.success(transaction))
            } catch {
                ZSLogger.error("[Checkout] preloadAll: purchase() failed: \(error)", category: .checkout)
                onComplete(.failure(error))
            }
            item = nil
            return
        }

        // Fast path: if background preload already has the WebView ready with
        // buttons painted, present immediately without any async hops.
        let preloader = pool.preloader(for: product.id)
        if preloader.isReady && preloader.buttonsReady,
           let url = preloader.loadedURL {
            ZSLogger.info("[Checkout] preloadAll: fast path — WebView ready, presenting immediately", category: .checkout)
            preloadedURL = url
            preloadedTransactionId = nil
            showSheet = true
            return
        }

        // Slow path: fetch PI from cache/server, load WebView if needed.
        guard let result = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else { return }
            onComplete(.failure(ZeroSettleError.checkoutFailed(reason: .other("Failed to create payment"))))
            item = nil
            return
        }

        guard !Task.isCancelled else { return }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        if !preloader.isReady {
            await preloader.loadAndWait(url: result.checkoutURL)
        }

        if !preloader.buttonsReady {
            await preloader.waitForButtonsReady()
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
            productIds: products.map(\.id), userId: userId
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
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetModifier<EmptyView>(
            isPresented: isPresented,
            product: product,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            header: { EmptyView() },
            onComplete: onComplete
        ))
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public func checkoutSheet(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        checkoutSheet(
            isPresented: isPresented,
            product: product,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            onComplete: onComplete
        )
    }

    /// Presents a ZeroSettle payment sheet with a custom header when `isPresented` is true.
    ///
    /// - Parameter preload: Optional declarative preloading. When set, payment intents are
    ///   created as soon as the view enters the hierarchy.
    public func checkoutSheet<Header: View>(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetModifier(
            isPresented: isPresented,
            product: product,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            header: header,
            onComplete: onComplete
        ))
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public func checkoutSheet<Header: View>(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        checkoutSheet(
            isPresented: isPresented,
            product: product,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            header: header,
            onComplete: onComplete
        )
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
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onPresent: (() -> Void)? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetItemModifier<EmptyView>(
            item: item,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            header: { EmptyView() },
            onPresent: onPresent,
            onComplete: onComplete
        ))
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public func checkoutSheet(
        item: Binding<ZSProduct?>,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onPresent: (() -> Void)? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        checkoutSheet(
            item: item,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            onPresent: onPresent,
            onComplete: onComplete
        )
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
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onPresent: (() -> Void)? = nil,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        modifier(CheckoutSheetItemModifier(
            item: item,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            header: header,
            onPresent: onPresent,
            onComplete: onComplete
        ))
    }

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    public func checkoutSheet<Header: View>(
        item: Binding<ZSProduct?>,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onPresent: (() -> Void)? = nil,
        @ViewBuilder header: @escaping () -> Header,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        checkoutSheet(
            item: item,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            onPresent: onPresent,
            header: header,
            onComplete: onComplete
        )
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
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
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

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    @MainActor
    public static func present(
        from viewController: UIViewController,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        present(
            from: viewController,
            product: product,
            userId: userId,
            dismissible: dismissible,
            checkoutURL: checkoutURL,
            transactionId: transactionId,
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
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: @escaping () -> H,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
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

    @available(*, deprecated, message: "freeTrialDays is ignored. Free trials are configured server-side.")
    @MainActor
    public static func present<H: View>(
        from viewController: UIViewController,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int,
        dismissible: Bool = true,
        checkoutURL: URL? = nil,
        transactionId: String? = nil,
        @ViewBuilder header: @escaping () -> H,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) {
        present(
            from: viewController,
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

/// Transparent bridge that preloads the PaymentIntent and WebView, then
/// presents `CheckoutSheet` via SwiftUI's `.sheet()` so
/// `.presentationDetents` works correctly when called from UIKit.
///
/// Mirrors the preloading behavior of `CheckoutSheetModifier` so the
/// user sees a fully-rendered checkout the moment the sheet slides up.
private struct UIKitSheetBridge<SheetHeader: View>: View {
    let product: ZSProduct
    let userId: String?
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
            .sheet(isPresented: $showSheet, onDismiss: {
                CheckoutPresentationCoordinator.shared.release()
                // Always reset the preloader — stale Stripe JS state causes
                // failures when a WebView is reused for a subsequent checkout.
                pool.reset(for: product.id)
                preloadedURL = nil
                preloadedTransactionId = nil
                onDismissed()
            }) {
                if let url = preloadedURL {
                    CheckoutSheet(
                        product: product,
                        userId: userId,
                        dismissible: dismissible,
                        preloader: pool.preloader(for: product.id),
                        checkoutURL: url,
                        transactionId: preloadedTransactionId,
                        header: header
                    ) { result in
                        if case .success = result {
                            Task { await CheckoutResponseCache.shared.invalidate(productId: product.id, userId: userId, publishableKey: ZeroSettle.shared.currentConfig?.publishableKey ?? "") }
                        }
                        onComplete(result)
                    }
                } else {
                    CheckoutSheet(
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
        guard checkoutType == .webView || checkoutType == .nativePay else {
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
            productId: product.id, userId: userId
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

        // Wait for payment buttons to be visually rendered before presenting
        if !preloader.buttonsReady {
            await preloader.waitForButtonsReady()
        }

        guard CheckoutPresentationCoordinator.shared.acquire(for: product.id) else {
            return
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
            userId: "user_123"
        ) { _ in }
    }
}
#endif
