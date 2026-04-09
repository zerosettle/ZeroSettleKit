import SwiftUI
import StoreKit
import WebKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

#if os(iOS)
import SafariServices
#endif

// MARK: - Unified Offer Tip View

/// Unified offer tip card for both migration and upgrade flows.
///
/// Drop-in replacement for ``MigrationTipView`` that supports all offer types.
/// All copy is server-configurable via ``Offer/Display``, with SDK defaults
/// as fallbacks for backward compatibility.
///
/// Usage:
/// ```swift
/// OfferTipView(userId: "user_123")
/// ```
public struct OfferTipView: View {

    /// Lifecycle events emitted by ``OfferTipView``.
    ///
    /// Use these with the ``onEvent`` callback to track user progression
    /// through the offer flow without polling ``ZSOfferManager/state``.
    public enum Event: Sendable {
        /// The user tapped the main CTA button to begin checkout.
        case ctaTapped
        /// The web checkout completed successfully. The user now has a web
        /// entitlement but their Apple subscription may still be active.
        case checkoutCompleted
        /// The user opened Apple's subscription-management sheet to cancel
        /// their Apple billing.
        case appleSubscriptionManagementOpened
        /// The full offer flow is finished -- web checkout succeeded **and**
        /// Apple subscription management was shown (if required).
        case offerCompleted
        /// The view was dismissed (close button, auto-dismiss after completion,
        /// or the user became ineligible).
        case dismissed
    }

    // MARK: - Stored Properties

    private let userId: String
    private let stripeCustomerId: String?
    private let backgroundColor: Color
    private let titleFont: Font?
    private let bodyFont: Font?
    private let ctaFont: Font?
    private let borderColor: Color?
    private let onEvent: ((Event) -> Void)?

    @ObservedObject private var manager: ZSOfferManager

    // MARK: - UI-only State

    @State private var showCongratulations = false
    @State private var checkingCancellation = false
    @State private var confettiTrigger = 0

    // WebView checkout state
    @State private var isExpanded = false
    @State private var ctaTapped = false
    @State private var webViewLoaded = false
    @State private var contentHeight: CGFloat = 180
    @State private var checkoutURL: URL?
    @State private var hasApplePay = false
    @StateObject private var preloader = MigrationCheckoutPreloader()
    @State private var preloadTriggered = false
    /// True when performing a web-to-web upgrade (no WebView, just a spinner).
    @State private var webToWebInProgress = false

    // Sheet checkout state (used when checkoutPresentation == .sheet)
    @State private var sheetCheckoutProduct: ZSProduct?

    // MARK: - Constants

    private static let collapsedHeight: CGFloat = 180
    private static let applePayCollapsedHeight: CGFloat = 180
    private static let noApplePayCollapsedHeight: CGFloat = 90

    // MARK: - Computed Helpers

    private var savings: Int {
        manager.offerData?.savingsPercent ?? 0
    }

    private var display: Offer.Display? {
        manager.display
    }

    /// Whether the current offer uses a WebView-based checkout (migration or storekit_to_web upgrade).
    private var usesWebViewCheckout: Bool {
        manager.offerData?.upgradeType != .webToWeb
    }

    // MARK: - Init

    /// Creates a new offer tip view.
    ///
    /// Uses the shared ``ZSOfferManager`` from ``ZeroSettle/offerManager(for:stripeCustomerId:)``
    /// (created during ``ZeroSettle/bootstrap(userId:)``). Falls back to creating a local
    /// instance if bootstrap hasn't run yet.
    ///
    /// - Parameters:
    ///   - userId: The user identifier passed to the checkout backend.
    ///   - stripeCustomerId: Optional existing Stripe Customer ID (`cus_xxx`) to attach the checkout to.
    ///     When `nil`, the backend creates a new customer.
    ///   - backgroundColor: The background color for the view. Defaults to `.black`.
    ///   - titleFont: Optional custom font for title text. When `nil`, the default system bold font is used.
    ///   - bodyFont: Optional custom font for body/message text. When `nil`, the default system font is used.
    ///   - ctaFont: Optional custom font for CTA button text. When `nil`, the default system bold font is used.
    ///   - borderColor: Optional border color applied as a rounded rectangle stroke on card views.
    ///     When `nil`, no border is drawn.
    ///   - onEvent: Optional closure invoked when a lifecycle ``Event`` occurs.
    public init(
        userId: String,
        stripeCustomerId: String? = nil,
        backgroundColor: Color = .black,
        titleFont: Font? = nil,
        bodyFont: Font? = nil,
        ctaFont: Font? = nil,
        borderColor: Color? = nil,
        onEvent: ((Event) -> Void)? = nil
    ) {
        self.userId = userId
        self.stripeCustomerId = stripeCustomerId
        self.backgroundColor = backgroundColor
        self.titleFont = titleFont
        self.bodyFont = bodyFont
        self.ctaFont = ctaFont
        self.borderColor = borderColor
        self.onEvent = onEvent

        let mgr = ZeroSettle.shared.offerManager(for: userId, stripeCustomerId: stripeCustomerId)
        _manager = ObservedObject(wrappedValue: mgr)
    }

    // MARK: - Body

    public var body: some View {
        Group {
            switch manager.state {
            case .loading, .ineligible:
                Color.clear.frame(height: 0)

            case .dismissed:
                EmptyView()

            case .eligible, .presented:
                offerCardView

            case .accepted:
                if checkingCancellation {
                    checkingCancellationView
                } else {
                    acceptedCardView
                }

            case .completed:
                if showCongratulations {
                    congratulationsCardView
                } else {
                    EmptyView()
                }
            }
        }
        .onChange(of: manager.state) { _, newState in
            if newState == .dismissed {
                onEvent?(.dismissed)
            }
            // Trigger preloading when becoming eligible (WebView flows only)
            if newState == .eligible && !preloadTriggered && usesWebViewCheckout {
                triggerPreload()
            }
            // Reset preloader when leaving eligible/presented
            if newState != .eligible && newState != .presented {
                preloader.reset()
                preloadTriggered = false
            }
        }
        .onChange(of: preloader.buttonsReady) { _, ready in
            if ready && !isExpanded && checkoutURL != nil {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded = true
                }
            }
        }
        .task {
            // Trigger preloading if already eligible when view appears
            if manager.state == .eligible && !preloadTriggered && usesWebViewCheckout {
                triggerPreload()
            }
        }
        // Sheet checkout path — presents the overlay checkout sheet instead of inline WebView.
        .checkoutSheet(
            item: $sheetCheckoutProduct,
            userId: userId,
            onPresent: { ctaTapped = false }
        ) { result in
            switch result {
            case .success(let txn):
                Task {
                    await manager.markCheckoutSucceeded(transactionId: txn.id)
                    onEvent?(.checkoutCompleted)
                    if manager.state == .accepted {
                        onEvent?(.appleSubscriptionManagementOpened)
                        await manager.showAppleSubscriptionManagement()
                        transitionToCompleted()
                    } else if manager.state == .completed {
                        transitionToCompleted()
                    }
                }
            case .failure(let error):
                ctaTapped = false
                if !ZeroSettleError.isCancellation(error) {
                    ZSLogger.error("[OfferTipView] Sheet checkout failed: \(error)", category: .checkout)
                }
            }
        }
    }

    // MARK: - Offer Card

    private var offerCardView: some View {
        VStack(spacing: 0) {
            headerView(
                icon: {
                    Text("\u{1F381}")
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                },
                title: display?.offerTitleOrDefault("Thanks for being with us!")
                    ?? "Thanks for being with us!",
                message: display?.offerMessageOrDefault(defaultOfferMessage)
                    ?? defaultOfferMessage,
                showCloseButton: true
            )

            // CTA button (hidden when WebView is expanded)
            if !isExpanded {
                if ctaTapped {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding(.bottom, 16)
                        .accessibilityLabel(
                            webToWebInProgress ? "Processing upgrade" : "Loading checkout"
                        )
                } else {
                    ctaButton(
                        label: display?.offerCtaOrDefault(defaultOfferCta) ?? defaultOfferCta,
                        accessibilityHint: "Opens the checkout to switch to direct billing",
                        action: handleCtaTapped
                    )
                }
            }

            // Inline WebView -- created when URL is available, revealed when buttons are visible
            if let checkoutURLValue = checkoutURL {
                VStack(spacing: 8) {
                    CheckoutWebView(
                        url: checkoutURLValue,
                        backgroundColor: UIColor(backgroundColor),
                        preloadedWebView: preloader.isReady ? preloader.webView : nil,
                        preloadedMessageRouter: preloader.isReady ? preloader.messageRouter : nil,
                        onLoaded: {
                            webViewLoaded = true
                        },
                        onPaymentMethodChanged: { paymentMethod in
                            handlePaymentMethodChanged(paymentMethod)
                        },
                        onContentHeightChanged: { height in
                            guard height > 50 else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                contentHeight = height
                            }
                        },
                        onCheckoutSuccess: { transactionId in
                            handleCheckoutSuccess(transactionId: transactionId)
                        }
                    )
                    .frame(height: isExpanded ? contentHeight : 0)
                    .opacity(isExpanded ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(isExpanded)
                    .cornerRadius(12)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Payment form")

                    if isExpanded {
                        Text("Cancel anytime.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }
                .padding(.bottom, isExpanded ? 16 : 0)
                .zIndex(-1)
                .transition(.opacity)
            }
        }
        .background(backgroundColor)
        .background(
            MigrationPreloaderHost(webView: preloader.webView)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        )
        .cornerRadius(16)
        .overlay {
            if let borderColor {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(borderColor, lineWidth: 2)
            }
        }
    }

    private var defaultOfferMessage: String {
        if savings > 0 {
            return "Switch to direct billing and get \(savings)% off forever. Same features, fewer platform fees, and we pass the savings onto you."
        }
        return "Switch to direct billing. Same features, fewer platform fees."
    }

    private var defaultOfferCta: String {
        savings > 0 ? "Save \(savings)% Forever" : "Switch Now"
    }

    // MARK: - Accepted Card (Cancel Apple Billing)

    private var acceptedCardView: some View {
        VStack(spacing: 0) {
            headerView(
                icon: { successCheckmark },
                title: display?.acceptedTitleOrDefault("Thanks for switching!")
                    ?? "Thanks for switching!",
                message: display?.acceptedMessageOrDefault(
                    "The last step is to cancel your Apple billing! Your card won't be charged until the end of your last Apple billing cycle. Pro features will continue uninterrupted."
                ) ?? "The last step is to cancel your Apple billing!",
                showCloseButton: false
            )

            ctaButton(
                label: display?.acceptedCtaOrDefault("Cancel Apple Billing")
                    ?? "Cancel Apple Billing",
                accessibilityHint: "Opens Apple subscription management to cancel your App Store billing",
                action: { Task { await openSubscriptionManagement() } }
            )
        }
        .offerCard(backgroundColor: backgroundColor, borderColor: borderColor)
    }

    // MARK: - Checking Cancellation

    private var checkingCancellationView: some View {
        VStack(spacing: 0) {
            headerView(
                icon: {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.regular)
                        .accessibilityLabel("Checking cancellation status")
                },
                title: "Checking status...",
                message: "Verifying your subscription was cancelled.",
                showCloseButton: false
            )
        }
        .accessibilityElement(children: .combine)
        .offerCard(backgroundColor: backgroundColor, borderColor: borderColor)
    }

    // MARK: - Congratulations Card

    private var congratulationsCardView: some View {
        VStack(spacing: 0) {
            headerView(
                icon: {
                    Text("\u{1F389}")
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                },
                title: display?.completedTitleOrDefault("Congratulations!")
                    ?? "Congratulations!",
                message: display?.completedMessageOrDefault(defaultCompletedMessage)
                    ?? defaultCompletedMessage,
                showCloseButton: false
            )
        }
        .accessibilityElement(children: .combine)
        .offerCard(backgroundColor: backgroundColor, borderColor: borderColor)
    }

    private var defaultCompletedMessage: String {
        savings > 0
            ? "You are now saving \(savings)% forever."
            : "You have successfully switched to direct billing."
    }

    // MARK: - Reusable Components

    private var successCheckmark: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 44, height: 44)
                .overlay(
                    Circle().stroke(.green, lineWidth: 3)
                )
            Image(systemName: "checkmark")
                .font(.title2.weight(.bold))
                .foregroundColor(.green)
        }
        .accessibilityLabel("Success")
    }

    private func headerView<Icon: View>(
        @ViewBuilder icon: () -> Icon,
        title: String,
        message: String,
        showCloseButton: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon()

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 8) {
                    Text(title)
                        .font(titleFont ?? .title3.weight(.bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Spacer()

                    if showCloseButton {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                if isExpanded {
                                    isExpanded = false
                                    ctaTapped = false
                                } else {
                                    manager.dismiss()
                                }
                            }
                        }) {
                            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .accessibilityLabel(isExpanded ? "Minimize" : "Close")
                        .accessibilityHint(isExpanded ? "Collapses the checkout form" : "Dismisses the offer")
                        .offset(y: -4)
                    }
                }

                Text(message)
                    .font(bodyFont ?? .subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .confettiCannon(
            trigger: $confettiTrigger,
            num: 50,
            openingAngle: Angle(degrees: 0),
            closingAngle: Angle(degrees: 360),
            radius: 200
        )
    }

    private func ctaButton(
        label: String,
        accessibilityHint hint: String = "Opens the checkout flow",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if manager.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: backgroundColor))
                        .scaleEffect(0.8)
                        .accessibilityHidden(true)
                }
                Text(manager.isLoading ? "" : label)
                    .font(ctaFont ?? .body.weight(.bold))
                    .foregroundColor(backgroundColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(Capsule())
        }
        .accessibilityHint(hint)
        .disabled(manager.isLoading)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Actions

    private func handleCtaTapped() {
        onEvent?(.ctaTapped)
        ctaTapped = true

        // Web-to-web upgrades: no WebView, just a loading spinner
        if manager.offerData?.upgradeType == .webToWeb {
            webToWebInProgress = true
            Task {
                _ = await manager.startCheckout(stripeCustomerId: stripeCustomerId)
                webToWebInProgress = false
                ctaTapped = false

                guard manager.state == .completed else { return }
                onEvent?(.checkoutCompleted)
                transitionToCompleted()
            }
            return
        }

        // Checkout presentation override from dashboard config.
        // When set, takes priority over the global checkoutType.
        // When nil, falls through to startWebViewCheckout() which uses checkoutType.
        switch manager.offerData?.checkoutPresentation {
        case .inline:
            startInlineWebViewCheckout()
            return
        case .sheet:
            startSheetCheckout()
            return
        case .safariVC, .safari:
            startBrowserCheckout()
            return
        case nil:
            break // No override — use global checkoutType below
        }

        startWebViewCheckout()
    }

    private func startSheetCheckout() {
        guard let productId = manager.offerData?.checkoutProductId,
              let product = ZeroSettle.shared.product(for: productId) else {
            ctaTapped = false
            return
        }
        manager.present()
        sheetCheckoutProduct = product
    }

    private func startWebViewCheckout() {
        let iap = ZeroSettle.shared
        let checkoutType = iap.checkoutType

        switch checkoutType {
        case .webView, .nativePay:
            startInlineWebViewCheckout()
        case .safari, .safariVC:
            startBrowserCheckout()
        }
    }

    private func startInlineWebViewCheckout() {
        Task {
            // Fastest path: WebView already loaded (re-expanding after minimize)
            if checkoutURL != nil {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded = true
                }
                return
            }

            // Fast path: preloader has URL and WebView ready
            if preloader.isReady, let url = await manager.preloadCheckout(stripeCustomerId: stripeCustomerId) {
                checkoutURL = url
                hasApplePay = preloader.hasApplePay
                if preloader.buttonsReady {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isExpanded = true
                    }
                }
                scheduleExpansionTimeout()
                return
            }

            // Slow path: PI creation on-demand
            let url = await manager.startCheckout(stripeCustomerId: stripeCustomerId)
            if let url {
                checkoutURL = url
                scheduleExpansionTimeout()
            } else {
                ctaTapped = false
            }
        }
    }

    /// Safety timeout: expand after 5s even if buttons_ready never fires.
    private func scheduleExpansionTimeout() {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !isExpanded && checkoutURL != nil {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded = true
                }
            }
        }
    }

    private func startBrowserCheckout() {
        manager.present()

        Task { @MainActor in
            guard manager.offerData != nil else {
                ctaTapped = false
                return
            }

            let url = await manager.startCheckout(stripeCustomerId: stripeCustomerId)
            guard let checkoutURL = url else {
                ctaTapped = false
                return
            }

            #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
                let rootVC = scene.windows.first(where: \.isKeyWindow)?
                    .rootViewController
            else {
                await UIApplication.shared.open(checkoutURL)
                return
            }

            let config = SFSafariViewController.Configuration()
            config.barCollapsingEnabled = false
            let safari = SFSafariViewController(url: checkoutURL, configuration: config)
            safari.preferredBarTintColor = UIColor(backgroundColor)
            safari.preferredControlTintColor = .white
            rootVC.present(safari, animated: true)
            #endif

            // Wait for the manager to transition to .accepted or .completed
            // after the checkout completes via deep link / universal link callback
        }
    }

    private func triggerPreload() {
        let iap = ZeroSettle.shared
        let checkoutType = iap.checkoutType

        // Only preload for inline WebView checkout types
        guard checkoutType == .webView || checkoutType == .nativePay else { return }

        // Respect the kill switch
        guard iap.currentConfig?.maxPreloadedWebViews != 0 else { return }

        preloadTriggered = true
        WebKitWarmup.warmIfNeeded()

        Task {
            guard let url = await manager.preloadCheckout(stripeCustomerId: stripeCustomerId) else { return }
            preloader.preload(url: url, backgroundColor: UIColor(backgroundColor))
        }
    }

    private func handlePaymentMethodChanged(_ paymentMethod: String) {
        switch paymentMethod {
        case "buttons_ready":
            if !isExpanded {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded = true
                }
            }
        case "apple_pay_detected":
            hasApplePay = true
            withAnimation(.easeInOut(duration: 0.25)) {
                contentHeight = Self.applePayCollapsedHeight
            }
        case "card_expanded":
            break // Expansion height is driven by onContentHeightChanged
        case "card_collapsed":
            let collapsed = hasApplePay
                ? Self.applePayCollapsedHeight
                : Self.noApplePayCollapsedHeight
            withAnimation(.easeInOut(duration: 0.25)) {
                contentHeight = collapsed
            }
        default:
            withAnimation(.easeInOut(duration: 0.25)) {
                contentHeight = Self.collapsedHeight
            }
        }
    }

    private func handleCheckoutSuccess(transactionId: String?) {
        withAnimation(.easeInOut(duration: 0.25)) {
            isExpanded = false
            webViewLoaded = false
            contentHeight = Self.collapsedHeight
            checkoutURL = nil
        }
        Task {
            await manager.markCheckoutSucceeded(transactionId: transactionId)
        }
        onEvent?(.checkoutCompleted)
    }

    @MainActor
    private func openSubscriptionManagement() async {
        withAnimation(.easeInOut(duration: 0.2)) {
            checkingCancellation = true
        }

        await manager.showAppleSubscriptionManagement()
        onEvent?(.appleSubscriptionManagementOpened)

        guard manager.state == .completed else {
            withAnimation(.easeInOut(duration: 0.2)) {
                checkingCancellation = false
            }
            return
        }

        transitionToCompleted()
    }

    private func transitionToCompleted() {
        showCongratulations = true

        withAnimation(.easeInOut(duration: 0.3)) {
            checkingCancellation = false
        }

        // Delay confetti so the congratulations view renders first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            confettiTrigger += 1
        }

        onEvent?(.offerCompleted)

        // Auto-dismiss after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                manager.dismiss()
            }
        }
    }
}

// MARK: - Card Style View Modifier

private struct OfferCardModifier: ViewModifier {
    let backgroundColor: Color
    let borderColor: Color?

    func body(content: Content) -> some View {
        content
            .background(backgroundColor)
            .cornerRadius(16)
            .overlay {
                if let borderColor {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 2)
                }
            }
    }
}

private extension View {
    func offerCard(backgroundColor: Color, borderColor: Color?) -> some View {
        modifier(OfferCardModifier(backgroundColor: backgroundColor, borderColor: borderColor))
    }
}
