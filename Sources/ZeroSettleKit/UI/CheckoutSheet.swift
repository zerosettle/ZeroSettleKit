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

import SafariServices
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
let setupMeasureJS = """
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
let measureContentJS = "window.__zsMeasure()"

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
let heightObserverJS = """
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
let buttonReadyJS = """
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
func parseJSHeight(_ result: Any?) -> CGFloat? {
    if let height = result as? CGFloat, height > 0 {
        return height
    } else if let number = result as? NSNumber, number.doubleValue > 0 {
        return CGFloat(number.doubleValue)
    }
    return nil
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
internal func migrationEndDate(for productId: String) -> Date? {
    guard let manager = ZeroSettle.shared.migrationManager,
          let offer = manager.offerData,
          offer.prompt.productId == productId else { return nil }
    return offer.storekitSubscriptionEnd
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

    /// Height of the clear-color inset reserved at the bottom of the sheet.
    /// Used in two places that must agree: the safeAreaInset that creates the
    /// breathing room, and the presentationDetent calculation that adds the
    /// inset back so the ScrollView content area equals natural content size.
    private let bottomInset: CGFloat = 20

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

    internal init(
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

        // Preloaded WebView is already fully rendered (buttons visible) —
        // start with loading overlay hidden. If the WebView re-navigates
        // (rare, process restart), buttonsReady will fire from JS.
        self._isLoading = State(initialValue: false)

        // Start the settling window to protect against the Stripe iframe feedback
        // loop (see file header §2). For trusted measurements, start immediately
        // since we already have a correct webContentHeight that could be inflated
        // by a live observer update. For untrusted, start on first accepted height.
        self._settleDeadline = State(initialValue: trustworthy ? Date().addingTimeInterval(0.8) : nil)

        self.header = header()
        self.onComplete = onComplete
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
            // Bottom breathing room. Done as inner content padding (not as a
            // safeAreaInset on the ScrollView) so the inset is part of the
            // natural VStack size, sheetHeight reflects the visible total,
            // and the detent stays on the same scale as the measured content.
            // Wiring it through safeAreaInset required adding bottomInset to
            // the detent calculation, which broke dynamic resize on card
            // collapse — SwiftUI's presentationDetents didn't follow the
            // value transition cleanly.
            .padding(.bottom, bottomInset)
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
        // FP tolerance: sheetHeight and scrollFrameHeight come from separate
        // GeometryProxy reads and can differ by ~1e-15 even when "the same."
        // Without slack, that flips scrollDisabled to false and the user can
        // drag content into empty space below the visible content.
        .scrollDisabled(sheetHeight <= scrollFrameHeight + 1.0)
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
        // Detent uses sheetHeight directly (no bottomInset add). The VStack
        // gets bottomInset of bottom padding below so the breathing room is
        // part of natural content size — this keeps the detent and the
        // measured sheetHeight on the same scale and lets dynamic resize
        // (card expand/collapse) animate cleanly. Adding the inset to the
        // detent caused the sheet not to shrink back on collapse.
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
            // Loading overlay is cleared by buttonsReady (JS signal), not
            // contentHeight. The buttonsReady timeout (5s) is the safety net.

            // Start the settling window on the first accepted height
            // (non-preloaded path; preloaded views set this in init).
            // Skip re-arming during an active expand bypass — the CSS
            // transition sends increasing heights that would be rejected.
            if settleDeadline == nil && height > 0 && !bypassing {
                settleDeadline = Date().addingTimeInterval(0.8)
            }

        case .openInSafari(let url):
            // Dismiss the WKWebView checkout sheet, then present SFSafariViewController
            // so popup-dependent methods (Klarna, PayPal, Link, Amazon Pay) work.
            // The transaction state is encoded in the URL fragment so the customer
            // continues seamlessly in Safari without any state loss.
            //
            // Capture the underlying presenter *before* calling dismiss().
            // After dismiss, the sheet is mid-transition and
            // SafariPresentation.topViewController() can transiently return
            // nil (the scene dips out of .foregroundActive during the
            // animation, or the sheet's hosting controller is still the
            // topmost while it slides away). Either way, presenting on a
            // stale or nil VC silently no-ops — the symptom is "tapping
            // dismisses the button but Safari never opens." Capturing the
            // presenter here pins us to the right anchor before the
            // hierarchy is in flux.
            let presenter = SafariPresentation.topViewController()?.presentingViewController
            dismiss()
            // Wait for the sheet dismiss animation to complete before presenting.
            // dismiss() returns immediately; the ~0.35s animation must finish first
            // or SFSafariViewController would try to present from the departing sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let safari = SFSafariViewController(url: url)
                safari.applyZSPageSheetPresentation()
                // Prefer the captured presenter; fall back to a fresh
                // topViewController walk in case the captured ref was nil
                // (rare — would mean the sheet wasn't actually presented
                // when we captured, which shouldn't happen here but the
                // fallback costs nothing).
                let target = presenter ?? SafariPresentation.topViewController()
                target?.present(safari, animated: true)
            }

        case .complete(let txnId):
            Task {
                await verifyAndComplete(transactionId: txnId)
            }

        case .cancelled:
            dismiss()
            onComplete(.failure(ZeroSettleError.cancelled))

        case .error(let message):
            ZSLogger.error("[CheckoutSheet] handleWebViewAction: ERROR — message=\"\(message)\" webView.url=\(preloadedWebView?.url?.redactedForLogs ?? "nil")", category: .checkout)
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
            ZSLogger.error("[CheckoutSheet] handleWebViewAction: firing onComplete(.failure) kind=\(kind) message=\"\(message)\"", category: .checkout)
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
            // Append the local fallback entitlement before firing onComplete so that
            // host apps which immediately call restoreEntitlements() / credit consumable
            // tokens in their completion handler see the new entitlement. Other checkout
            // paths (purchase(), ZSMigrationManager, ZSOfferManager) already do this —
            // the .checkoutSheet WebView branch was the only gap.
            await ZeroSettle.shared.refreshEntitlementsAfterCheckout(transaction: transaction)
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
    /// The "More ways to pay" button was tapped — continue payment in Safari.
    case openInSafari(URL)
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
            let wvURL = preloaded.url?.redactedForLogs ?? "nil"
            let inWindow = preloaded.window != nil
            ZSLogger.info("[PaymentWebView] makeUIView: reusing preloaded WebView. url=\(wvURL) inWindow=\(inWindow) superview=\(preloaded.superview != nil)", category: .checkout)

            preloaded.removeFromSuperview()
            preloaded.navigationDelegate = context.coordinator
            context.coordinator.webView = preloaded

            messageRouter?.onMessage = { [weak coordinator = context.coordinator] message in
                guard let coordinator = coordinator else { return }
                coordinator.userContentController(WKUserContentController(), didReceive: message)
            }

            return preloaded
        }

        ZSLogger.info("[PaymentWebView] makeUIView: creating fresh WebView (no preloaded)", category: .checkout)

        // Standard path: create a new WebView
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WebKitWarmup.processPool
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "checkoutComplete")
        configuration.userContentController.add(context.coordinator, name: "consoleLog")
        configuration.userContentController.add(context.coordinator, name: "openInSafari")

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
            // Handle openInSafari before the checkoutComplete guard so it doesn't get dropped.
            if message.name == "openInSafari",
               let body = message.body as? [String: Any],
               let urlString = body["url"] as? String,
               let url = URL(string: urlString) {
                onAction(.openInSafari(url))
                return
            }

            guard message.name == "checkoutComplete",
                  let body = message.body as? [String: Any] else { return }

            let action = body["action"] as? String ?? ""
            ZSLogger.info("[CheckoutSheet] JS message: action=\(action) body=\(body.keys.sorted().joined(separator: ",")) hasCompleted=\(hasCompleted)", category: .checkout)

            switch action {
            case "ready":
                ZSLogger.info("[CheckoutSheet] JS: ready received — waiting for buttonsReady", category: .checkout)
                onAction(.ready)

            case "contentHeight":
                if let height = parseJSHeight(body["height"]) {
                    onAction(.contentHeight(height))
                }

            case "expandSheet":
                onAction(.expandSheet)
            case "collapseSheet":
                break
            case "buttonsReady":
                ZSLogger.info("[CheckoutSheet] JS: buttonsReady — clearing loading overlay", category: .checkout)
                DispatchQueue.main.async {
                    self.isLoading = false
                }

            case "complete":
                guard !hasCompleted else {
                    ZSLogger.info("[CheckoutSheet] JS: complete — IGNORED (already completed)", category: .checkout)
                    return
                }
                hasCompleted = true
                if let success = body["success"] as? Bool, success,
                   let transactionId = body["transaction_id"] as? String {
                    ZSLogger.info("[CheckoutSheet] JS: complete SUCCESS txn=\(transactionId)", category: .checkout)
                    onAction(.complete(transactionId: transactionId))
                } else {
                    let errorMessage = body["error"] as? String ?? "Payment failed"
                    ZSLogger.error("[CheckoutSheet] JS: complete FAILED — error=\(errorMessage) body=\(body)", category: .checkout)
                    onAction(.error(errorMessage))
                }

            case "error":
                let errorMessage = body["message"] as? String ?? "Checkout error"
                ZSLogger.error("[CheckoutSheet] JS: error — message=\(errorMessage) body=\(body)", category: .checkout)
                onAction(.error(errorMessage))

            default:
                // Legacy checkout pages may send completion without a recognized
                // action name. Only treat the message as a terminal event if it
                // contains checkout-result fields (success, cancelled, error).
                // Truly unrecognized actions are logged and ignored — this
                // prevents new JS signals from being misinterpreted as failures.
                let hasTerminalField = body["success"] != nil || body["cancelled"] != nil || body["error"] != nil
                guard hasTerminalField else {
                    ZSLogger.info("[CheckoutSheet] JS: unrecognized action=\(action) — ignoring (no terminal fields)", category: .checkout)
                    return
                }
                guard !hasCompleted else {
                    ZSLogger.info("[CheckoutSheet] JS: default action=\(action) — IGNORED (already completed)", category: .checkout)
                    return
                }
                hasCompleted = true
                if let success = body["success"] as? Bool, success,
                   let transactionId = body["transaction_id"] as? String {
                    ZSLogger.info("[CheckoutSheet] JS: default complete SUCCESS txn=\(transactionId)", category: .checkout)
                    onAction(.complete(transactionId: transactionId))
                } else if let cancelled = body["cancelled"] as? Bool, cancelled {
                    ZSLogger.info("[CheckoutSheet] JS: default cancelled", category: .checkout)
                    onAction(.cancelled)
                } else {
                    let errorMessage = body["error"] as? String ?? "Payment failed"
                    ZSLogger.error("[CheckoutSheet] JS: default FAILED — error=\(errorMessage) body=\(body)", category: .checkout)
                    onAction(.error(errorMessage))
                }
            }
        }

        // MARK: - Navigation Delegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ZSLogger.info("[CheckoutSheet] Coordinator: webView didFinish navigation. url=\(webView.url?.redactedForLogs ?? "nil")", category: .checkout)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            ZSLogger.error("[CheckoutSheet] Coordinator: webView didFail navigation. error=\(error.localizedDescription) url=\(webView.url?.redactedForLogs ?? "nil")", category: .checkout)
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ZSLogger.error("[CheckoutSheet] Coordinator: PROCESS TERMINATED while sheet is visible! url=\(webView.url?.redactedForLogs ?? "nil")", category: .checkout)
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
