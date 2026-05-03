//
//  CheckoutModifier.swift
//  ZeroSettleKit
//
//  ViewModifiers, bridge views, and helpers for presenting CheckoutSheet.
//  Extracted from CheckoutSheet.swift to keep the core view lean.
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif
#endif

// MARK: - Active Window Scene Helper

/// Returns the foreground-active UIWindowScene for creating overlay windows.
/// Used by checkout modifiers to present via a dedicated UIWindow,
/// escaping any SwiftUI nested-sheet height constraints.
internal func activeWindowScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
}

// MARK: - Shared Success Handler

/// Error message shown when the buttonsReady timeout fires.
private let checkoutTimeoutMessage = "Checkout timed out — payment buttons failed to load. Please check your internet connection and try again."

/// Waits for `ZeroSettle.shared.isBootstrapped` with a 10-second timeout.
/// Returns `true` if bootstrapped, `false` on timeout or cancellation.
@MainActor
internal func awaitBootstrap() async -> Bool {
    if ZeroSettle.shared.isBootstrapped { return true }
    let deadline = CFAbsoluteTimeGetCurrent() + 10
    while !ZeroSettle.shared.isBootstrapped, CFAbsoluteTimeGetCurrent() < deadline {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return false }
    }
    return ZeroSettle.shared.isBootstrapped
}

/// Delegate a checkout to `ZeroSettle.shared.purchase()` — used by the
/// three SwiftUI checkout modifiers when `checkoutType` is `.safari` or
/// `.safariVC` (any type other than `.webView` / `.nativePay`). Those
/// types open a browser flow and don't need the modifier's WebView
/// preload machinery, so the modifier just forwards the purchase.
///
/// The `onFinally` closure resets the modifier's presentation state —
/// callers pass `{ isPresented = false }`, `{ item = nil }`, or
/// `onDismissed` depending on which modifier they are.
@MainActor
internal func performSafariCheckout(
    product: ZSProduct,
    userId: String?,
    checkoutType: CheckoutType,
    onComplete: (Result<CheckoutTransaction, Error>) -> Void,
    onFinally: () -> Void
) async {
    ZSLogger.info("[Checkout] safari delegation: routing to purchase() for \(checkoutType.rawValue)", category: .checkout)
    do {
        let transaction = try await ZeroSettle.shared.purchase(
            productId: product.id, userId: userId
        )
        onComplete(.success(transaction))
    } catch {
        ZSLogger.error("[Checkout] safari delegation: purchase() failed: \(error)", category: .checkout)
        onComplete(.failure(error))
    }
    onFinally()
}

/// Invalidates caches, resets preloader, and eagerly re-preloads after a successful checkout.
/// Shared across `CheckoutSheetModifier`, `CheckoutSheetItemModifier`, and
/// `UIKitSheetBridge` to eliminate duplicated post-success logic.
///
/// Callers are responsible for nilling out their own `preloadedURL`/`preloadedTransactionId`
/// @State properties after calling this.
@MainActor
internal func handleCheckoutSuccess(
    product: ZSProduct,
    userId: String?,
    pool: CheckoutPreloaderPool
) {
    Task {
        await CheckoutResponseCache.shared.invalidate(
            productId: product.id,
            userId: userId,
            publishableKey: ZeroSettle.shared.currentConfig?.publishableKey ?? ""
        )
    }
    pool.reset(for: product.id)
    // Eagerly re-preload this product so the next checkout is instant.
    Task { @MainActor in
        let ct = ZeroSettle.shared.checkoutType
        guard ct == .webView || ct == .nativePay else { return }
        guard let fresh = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else { return }
        let p = pool.preloader(for: product.id)
        await p.loadAndWait(url: fresh.checkoutURL)
        pool.refreshWebViews()
    }
}

// MARK: - Sheet Dismiss Detector (UIKit lifecycle)

/// Detects the START of a sheet dismiss animation via UIKit's `viewWillDisappear`,
/// which fires before the animation begins — unlike SwiftUI's `onDismiss` which fires after.
/// Place inside `.sheet()` content as a `.background` to get a callback when dismiss starts.
internal struct SheetDismissDetector: UIViewControllerRepresentable {
    let onWillDismiss: () -> Void

    func makeUIViewController(context: Context) -> SheetDismissDetectorVC {
        SheetDismissDetectorVC(onWillDismiss: onWillDismiss)
    }
    func updateUIViewController(_ vc: SheetDismissDetectorVC, context: Context) {}
}

internal class SheetDismissDetectorVC: UIViewController {
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
internal struct WindowLevelSheetBridge<SheetHeader: View>: View {
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
        // Scrim isolated inside a ZStack so the .sheet modifier below attaches
        // to the wrapper, not to the Color directly. With .sheet on the same
        // view as the scrim, SwiftUI interpolates the Color's opacity during
        // the system's drag-to-dismiss re-render, and the implicit
        // .animation(value:) below latches onto that interpolation. On
        // drag-and-snap-back, the value-of-record is the post-drag (reduced)
        // opacity, so the scrim never returns to 0.6.
        ZStack {
            Color.black.opacity(scrimVisible ? 0.6 : 0)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .animation(.easeOut(duration: 0.35), value: scrimVisible)
        }
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

// MARK: - SwiftUI View Modifier (isPresented-based)

/// Preloads the PaymentIntent AND the WebView before presenting the sheet.
/// The user sees a fully-rendered checkout the moment it slides up.
internal struct CheckoutSheetModifier<Header: View>: ViewModifier {
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
            .task(id: userId) {
                // Key on userId so an account switch:
                //  (a) discards the previous user's preloaded PI URL/txn,
                //  (b) re-runs the warm-up for the current user, and
                //  (c) never presents a sheet with someone else's client_secret.
                preloadedURL = nil
                preloadedTransactionId = nil
                WebKitWarmup.warmIfNeeded()
                if let preload {
                    Task { @MainActor in
                        await preloadProducts(preload)
                    }
                }
            }
            .task(id: isPresented) {
                if isPresented {
                    // Jurisdiction gate: if web checkout is disabled for the
                    // detected jurisdiction (per the dashboard's per-jurisdiction
                    // override or global setting), refuse to present the sheet.
                    // This mirrors `ZeroSettle.shared.purchase()`'s behavior — without
                    // this gate, devs who set a jurisdiction override on the
                    // dashboard would silently see the sheet present in disabled
                    // regions, bypassing their own opt-out.
                    if !ZeroSettle.shared.isWebCheckoutEnabled {
                        let jurisdiction = ZeroSettle.shared.effectiveJurisdiction
                        ZSLogger.error(
                            "[CheckoutSheet] Refusing to present — web checkout disabled for \(jurisdiction.rawValue) jurisdiction. Configure this in your ZeroSettle dashboard under Checkout Configuration.",
                            category: .checkout
                        )
                        onComplete(.failure(
                            ZeroSettleError.webCheckoutDisabledForJurisdiction(jurisdiction)
                        ))
                        isPresented = false
                        return
                    }
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
                            handleCheckoutSuccess(
                                product: product,
                                userId: userId,
                                pool: pool
                            )
                            preloadedURL = nil
                            preloadedTransactionId = nil
                        }
                        onComplete(result)
                    },
                    onDismissed: {
                        CheckoutPresentationCoordinator.shared.release()
                        // Delay teardown so the system's dismiss animation
                        // can finish before the overlay window disappears.
                        let window = overlayWindow
                        window?.isUserInteractionEnabled = false
                        overlayWindow = nil
                        isPresented = false
                        showSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            window?.isHidden = true
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

    /// Prepares and presents the checkout sheet.
    ///
    /// Flow: bootstrap wait → checkout type guard → fetch PI → ensureReady → present.
    /// See `CheckoutPreloaderPool.ensureReady(for:url:)` for WebView readiness logic.
    private func preloadAll() async {
        guard await awaitBootstrap() else { return }

        let checkoutType = ZeroSettle.shared.checkoutType

        // ── Safari / SafariVC — delegate to purchase() which opens the browser ──
        guard checkoutType == .webView || checkoutType == .nativePay else {
            await performSafariCheckout(
                product: product, userId: userId, checkoutType: checkoutType,
                onComplete: onComplete, onFinally: { isPresented = false }
            )
            return
        }

        // ── Fetch PaymentIntent (cached or fresh) ──
        guard let result = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else { return }
            onComplete(.failure(ZeroSettleError.checkoutFailed(reason: .other("Failed to create payment for \(product.id). Check that the product has a valid web price configured in the ZeroSettle dashboard."))))
            isPresented = false
            return
        }

        guard !Task.isCancelled else { return }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        // ── Ensure WebView is loaded with payment buttons visible ──
        let ready = await pool.ensureReady(for: product.id, url: result.checkoutURL)
        if !ready {
            guard !Task.isCancelled else { return }
            onComplete(.failure(ZeroSettleError.checkoutFailed(
                reason: .other(checkoutTimeoutMessage)
            )))
            isPresented = false
            return
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
internal struct CheckoutSheetItemModifier<Header: View>: ViewModifier {
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
            .task(id: userId) {
                // Key on userId so an account switch:
                //  (a) discards the previous user's preloaded PI URL/txn,
                //  (b) re-runs the warm-up for the current user, and
                //  (c) never presents a sheet with someone else's client_secret.
                preloadedURL = nil
                preloadedTransactionId = nil
                WebKitWarmup.warmIfNeeded()
                if let preload {
                    Task { @MainActor in
                        await preloadProducts(preload)
                    }
                }
            }
            .task(id: item?.id) {
                if let product = item {
                    // Jurisdiction gate — see same comment in CheckoutSheetModifier.
                    if !ZeroSettle.shared.isWebCheckoutEnabled {
                        let jurisdiction = ZeroSettle.shared.effectiveJurisdiction
                        ZSLogger.error(
                            "[CheckoutSheet] Refusing to present — web checkout disabled for \(jurisdiction.rawValue) jurisdiction. Configure this in your ZeroSettle dashboard under Checkout Configuration.",
                            category: .checkout
                        )
                        onComplete(.failure(
                            ZeroSettleError.webCheckoutDisabledForJurisdiction(jurisdiction)
                        ))
                        item = nil
                        return
                    }
                    presentedProduct = product
                    // Clear stale preloaded state from a different product.
                    // Without this, the fast path serves the wrong product's checkout.
                    preloadedURL = nil
                    preloadedTransactionId = nil
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
                            handleCheckoutSuccess(
                                product: product,
                                userId: userId,
                                pool: pool
                            )
                            preloadedURL = nil
                            preloadedTransactionId = nil
                        }
                        onComplete(result)
                    },
                    onDismissed: {
                        CheckoutPresentationCoordinator.shared.release()
                        let window = overlayWindow
                        window?.isUserInteractionEnabled = false
                        overlayWindow = nil
                        item = nil
                        showSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            window?.isHidden = true
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

    /// Prepares and presents the checkout sheet for a specific product.
    ///
    /// Flow: bootstrap wait → checkout type guard → fast path → fetch PI →
    /// `pool.ensureReady()` → present.
    ///
    /// The fast path skips all async work when the previous checkout's PI and
    /// WebView are still cached and alive (e.g., user dismissed without purchasing).
    private func preloadAll(product: ZSProduct) async {
        let start = CFAbsoluteTimeGetCurrent()

        guard await awaitBootstrap() else {
            ZSLogger.error("[Checkout] preloadAll: bootstrap timed out for \(product.id)", category: .checkout)
            return
        }

        let checkoutType = ZeroSettle.shared.checkoutType

        // ── Safari / SafariVC — delegate to purchase() which opens the browser ──
        guard checkoutType == .webView || checkoutType == .nativePay else {
            await performSafariCheckout(
                product: product, userId: userId, checkoutType: checkoutType,
                onComplete: onComplete, onFinally: { item = nil }
            )
            return
        }

        let preloader = pool.preloader(for: product.id)
        ZSLogger.info("[Checkout] preloadAll START: product=\(product.id), checkoutType=\(checkoutType.rawValue), isBootstrapped=true, hasURL=\(preloadedURL != nil), hasTxnId=\(preloadedTransactionId != nil), preloaderAlive=\(preloader.isAlive)", category: .checkout)

        // ── Fast path: PI + WebView still warm from previous presentation ──
        // Requires bootstrap complete (pre-bootstrap PIs may be invalid) and
        // buttonsReady true (preloader.isAlive alone doesn't guarantee buttons).
        if preloadedURL != nil, preloadedTransactionId != nil,
           preloader.isAlive, preloader.buttonsReady {
            ZSLogger.info("[Checkout] preloadAll: FAST PATH — presenting in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms", category: .checkout)
            showSheet = true
            return
        }

        // ── Fetch PaymentIntent (cached or fresh) ──
        let preloadStart = CFAbsoluteTimeGetCurrent()
        guard let result = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else {
                ZSLogger.info("[Checkout] preloadAll: cancelled during preload", category: .checkout)
                return
            }
            ZSLogger.error("[Checkout] preloadAll: preload() returned nil after \(Int((CFAbsoluteTimeGetCurrent() - preloadStart) * 1000))ms — no PI created", category: .checkout)
            onComplete(.failure(ZeroSettleError.checkoutFailed(reason: .other("Failed to create payment for \(product.id). Check that the product has a valid web price configured in the ZeroSettle dashboard."))))
            item = nil
            return
        }
        ZSLogger.info("[Checkout] preloadAll: PI fetched in \(Int((CFAbsoluteTimeGetCurrent() - preloadStart) * 1000))ms (url=\(result.checkoutURL.redactedForLogs))", category: .checkout)

        guard !Task.isCancelled else {
            ZSLogger.info("[Checkout] preloadAll: cancelled after PI fetch", category: .checkout)
            return
        }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        // ── Ensure WebView is loaded with payment buttons visible ──
        let wvStart = CFAbsoluteTimeGetCurrent()
        let ready = await pool.ensureReady(for: product.id, url: result.checkoutURL)
        ZSLogger.info("[Checkout] preloadAll: ensureReady=\(ready) in \(Int((CFAbsoluteTimeGetCurrent() - wvStart) * 1000))ms", category: .checkout)

        if !ready {
            guard !Task.isCancelled else { return }
            ZSLogger.error("[Checkout] preloadAll: payment buttons never loaded for \(product.id)", category: .checkout)
            onComplete(.failure(ZeroSettleError.checkoutFailed(
                reason: .other(checkoutTimeoutMessage)
            )))
            item = nil
            return
        }

        guard !Task.isCancelled else {
            ZSLogger.info("[Checkout] preloadAll: cancelled after ensureReady", category: .checkout)
            return
        }
        ZSLogger.info("[Checkout] preloadAll DONE: presenting sheet, total \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms", category: .checkout)
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

// MARK: - UIKit Sheet Bridge

/// Transparent bridge that preloads the PaymentIntent and WebView, then
/// presents `CheckoutSheet` via SwiftUI's `.sheet()` so
/// `.presentationDetents` works correctly when called from UIKit.
///
/// Mirrors the preloading behavior of `CheckoutSheetModifier` so the
/// user sees a fully-rendered checkout the moment the sheet slides up.
internal struct UIKitSheetBridge<SheetHeader: View>: View {
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
                            handleCheckoutSuccess(
                                product: product,
                                userId: userId,
                                pool: pool
                            )
                            preloadedURL = nil
                            preloadedTransactionId = nil
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

    /// Prepares and presents the checkout sheet via UIKit window overlay.
    ///
    /// Flow: bootstrap wait → checkout type guard → fetch PI → ensureReady → present.
    /// See `CheckoutPreloaderPool.ensureReady(for:url:)` for WebView readiness logic.
    private func preloadAll() async {
        guard await awaitBootstrap() else { return }

        let checkoutType = ZeroSettle.shared.checkoutType

        // ── Safari / SafariVC — delegate to purchase() which opens the browser ──
        guard checkoutType == .webView || checkoutType == .nativePay else {
            await performSafariCheckout(
                product: product, userId: userId, checkoutType: checkoutType,
                onComplete: onComplete, onFinally: onDismissed
            )
            return
        }

        // ── Resolve checkout URL (caller-provided or fetched) ──
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
            guard !Task.isCancelled else { return }
            onComplete(.failure(ZeroSettleError.checkoutFailed(reason: .other("Failed to create payment for \(product.id). Check that the product has a valid web price configured in the ZeroSettle dashboard."))))
            onDismissed()
            return
        }

        // ── Ensure WebView is loaded with payment buttons visible ──
        let ready = await pool.ensureReady(for: product.id, url: url)
        if !ready {
            guard !Task.isCancelled else { return }
            onComplete(.failure(ZeroSettleError.checkoutFailed(
                reason: .other(checkoutTimeoutMessage)
            )))
            onDismissed()
            return
        }

        guard CheckoutPresentationCoordinator.shared.acquire(for: product.id) else {
            return
        }

        showSheet = true
    }
}
