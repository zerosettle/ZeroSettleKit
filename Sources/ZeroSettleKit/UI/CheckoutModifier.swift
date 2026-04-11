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
internal import ZeroSettleCore
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

    private func preloadAll(product: ZSProduct) async {
        let start = CFAbsoluteTimeGetCurrent()
        let checkoutType = ZeroSettle.shared.checkoutType
        let jurisdiction = ZeroSettle.shared.detectedJurisdiction
        let bootstrapped = ZeroSettle.shared.isBootstrapped
        let preloader = pool.preloader(for: product.id)
        ZSLogger.info("[Checkout] preloadAll START: product=\(product.id), checkoutType=\(checkoutType.rawValue), jurisdiction=\(jurisdiction.map { String(describing: $0) } ?? "nil"), isBootstrapped=\(bootstrapped), hasURL=\(preloadedURL != nil), hasTxnId=\(preloadedTransactionId != nil), preloaderReady=\(preloader.isReady), preloaderAlive=\(preloader.isAlive)", category: .checkout)

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

        // Fast path: URL, transaction ID, and WebView all still warm from a
        // previous presentation (e.g., user dismissed without purchasing).
        // Present immediately without any async hops.
        // Requires bootstrap to be complete — pre-bootstrap PIs may be invalid.
        if preloadedURL != nil, preloadedTransactionId != nil,
           preloader.isAlive,
           bootstrapped {
            ZSLogger.info("[Checkout] preloadAll: FAST PATH — presenting in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms", category: .checkout)
            showSheet = true
            return
        }

        // Fetch PI from cache (or server if cache miss), load WebView if needed.
        let preloadStart = CFAbsoluteTimeGetCurrent()
        guard let result = await CheckoutSheet<EmptyView>.preload(
            productId: product.id, userId: userId
        ) else {
            guard !Task.isCancelled else {
                ZSLogger.info("[Checkout] preloadAll: cancelled during preload", category: .checkout)
                return
            }
            ZSLogger.error("[Checkout] preloadAll: preload() returned nil after \(Int((CFAbsoluteTimeGetCurrent() - preloadStart) * 1000))ms — no PI created", category: .checkout)
            onComplete(.failure(ZeroSettleError.checkoutFailed(reason: .other("Failed to create payment"))))
            item = nil
            return
        }
        ZSLogger.info("[Checkout] preloadAll: PI fetched in \(Int((CFAbsoluteTimeGetCurrent() - preloadStart) * 1000))ms (url=\(result.checkoutURL.absoluteString.prefix(80))...)", category: .checkout)

        guard !Task.isCancelled else {
            ZSLogger.info("[Checkout] preloadAll: cancelled after PI fetch", category: .checkout)
            return
        }
        preloadedURL = result.checkoutURL
        preloadedTransactionId = result.transactionId

        if !preloader.isAlive {
            if preloader.isReady {
                ZSLogger.info("[Checkout] preloadAll: WebView was ready but process died — resetting", category: .checkout)
                preloader.reset()
            }
            let wvStart = CFAbsoluteTimeGetCurrent()
            await preloader.loadAndWait(url: result.checkoutURL)
            ZSLogger.info("[Checkout] preloadAll: WebView loaded in \(Int((CFAbsoluteTimeGetCurrent() - wvStart) * 1000))ms", category: .checkout)
        } else {
            ZSLogger.info("[Checkout] preloadAll: WebView alive, skipping loadAndWait", category: .checkout)
        }

        if !preloader.buttonsReady {
            let btnStart = CFAbsoluteTimeGetCurrent()
            await preloader.waitForButtonsReady()
            ZSLogger.info("[Checkout] preloadAll: buttons ready in \(Int((CFAbsoluteTimeGetCurrent() - btnStart) * 1000))ms", category: .checkout)
        } else {
            ZSLogger.info("[Checkout] preloadAll: buttons already ready, skipping wait", category: .checkout)
        }

        guard !Task.isCancelled else {
            ZSLogger.info("[Checkout] preloadAll: cancelled after WebView/buttons ready", category: .checkout)
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
