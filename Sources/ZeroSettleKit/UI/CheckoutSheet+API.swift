//
//  CheckoutSheet+API.swift
//  ZeroSettleKit
//
//  Public View modifier overloads and static convenience methods for
//  presenting CheckoutSheet. Extracted from CheckoutSheet.swift to keep
//  the core view lean.
//

import SwiftUI
import WebKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Static Preload / WarmUp API

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
            ZSLogger.info("[Checkout] preload(\(productId)): no webPrice — skipping", category: .checkout)
            return nil
        }

        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            ZSLogger.error("[Checkout] preload(\(productId)): no config/baseURL", category: .checkout)
            return nil
        }

        let pk = config.publishableKey

        let response = await CheckoutResponseCache.shared.fetchOrJoin(
            productId: productId, userId: userId, publishableKey: pk
        ) {
            let backend = Backend(baseURL: baseURL, publishableKey: pk)
            do {
                return try await backend.initiateCheckout(
                    productId: productId, userId: userId,
                    storekitSubscriptionEnd: migrationEndDate(for: productId)
                )
            } catch {
                ZSLogger.error("[Checkout] PI creation error for \(productId): \(error)", category: .checkout)
                return nil
            }
        }

        guard let response, let url = URL(string: response.checkoutUrl) else {
            ZSLogger.error("[Checkout] preload(\(productId)): fetchOrJoin returned nil or bad URL", category: .checkout)
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

        // Throttle: coalesce back-to-back warmups (same productIds, same userId)
        // within 5s. Common cause of duplicate warmups is host apps calling
        // bootstrap() twice during initial load — e.g., a SwiftUI .task(id:)
        // modifier whose ID flips on transient state change. We can't fix the
        // host app, but the SDK can refuse to spam the backend.
        //
        // Cache is the source of truth for "is this freshly warmed?" — but
        // CheckoutResponseCache TTL is 30 min and we don't want to lock out
        // intentional re-warmups across a full session. 5s is the
        // back-to-back-call window only.
        let throttleKey = WarmupThrottle.key(productIds: productIds, userId: userId)
        if await WarmupThrottle.shared.shouldSkip(key: throttleKey) {
            ZSLogger.info(
                "[Backend] warmUp throttled — last call within 5s for the same productIds+userId",
                category: .checkout,
            )
            return
        }
        await WarmupThrottle.shared.markFired(key: throttleKey)

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
        // Pre-flight: when the merchant is Apple-Pay-only, refuse to present
        // checkout if the device cannot complete it. Reports via onComplete so
        // callers handle it through the same Result path as any other checkout
        // failure. When `applePaySetupBehavior == .presentBuiltInUI`, also
        // open the system Wallet setup so the buyer can add a card without an
        // extra tap — see ApplePayPreflightGate for the decision matrix.
        let outcome = ApplePayPreflightGate.evaluate(
            isApplePayOnly: ZeroSettle.shared.isApplePayOnly,
            state: ZeroSettle.shared.applePayAvailability.state,
            behavior: ZeroSettle.shared.currentConfig?.applePaySetupBehavior ?? .presentBuiltInUI
        )
        if case .blocked(let error, let openSetupUI) = outcome {
            ZSLogger.info("[Checkout] present blocked — error=\(error) openSetupUI=\(openSetupUI)", category: .checkout)
            if openSetupUI {
                ZeroSettle.shared.presentApplePaySetup()
            }
            onComplete(.failure(error))
            return
        }

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

// MARK: - SwiftUI View Extensions

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


// MARK: - Warmup throttle

/// Coalesces back-to-back ``warmUp(productIds:userId:)`` calls within a
/// short window. The dedup key is ``(sortedProductIds, userId)`` so
/// calls for different products don't mask each other; the window is
/// short (5s) so deliberate refreshes still go through. Cache-based
/// dedup (CheckoutResponseCache, 30 min TTL) covers the broader case.
///
/// Common trigger for redundant warmups: SwiftUI ``.task(id: ...)`` host
/// modifiers whose ID flips on transient state during initial load,
/// re-firing the bootstrap closure that ultimately calls warmUp.
private actor WarmupThrottle {
    static let shared = WarmupThrottle()

    private var lastFiredAt: [String: Date] = [:]
    private let window: TimeInterval = 5.0

    static func key(productIds: [String], userId: String?) -> String {
        let sorted = productIds.sorted().joined(separator: ",")
        return "\(userId ?? "")|\(sorted)"
    }

    func shouldSkip(key: String) -> Bool {
        guard let last = lastFiredAt[key] else { return false }
        return Date().timeIntervalSince(last) < window
    }

    func markFired(key: String) {
        lastFiredAt[key] = Date()
    }
}
