import SwiftUI
import StoreKit
import WebKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

#if os(iOS)
import SafariServices
#endif

#if os(iOS)
/// Manages the lifecycle of an imperatively presented `SFSafariViewController`
/// for offer-flow browser checkouts. Two responsibilities:
///   1. Reset `OfferTipView.ctaTapped` on user-initiated dismissal. Both
///      delegate paths must be wired: `safariViewControllerDidFinish` fires
///      only on the Done/X button; swipe-down dismissal goes exclusively
///      through `presentationControllerDidDismiss`.
///   2. Programmatically dismiss the sheet when the offer manager advances
///      past `.presented` (e.g., a Universal Link callback transitions to
///      `.accepted`). Without this the SafariVC stays on top of the success
///      view, hiding it.
@MainActor
private final class OfferSafariCoordinator: NSObject {
    var onDismiss: (() -> Void)?
    weak var presentedSafari: SFSafariViewController?

    fileprivate func fireOnce() {
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        onDismiss?()
        presentedSafari = nil
    }

    /// Dismisses the SafariVC if it's still presented. Use after the manager
    /// state advances past `.presented` (success path). Neither delegate
    /// callback fires for programmatic dismiss, so this also nils `onDismiss`
    /// to release the captured `manager` reference.
    func dismissIfPresented() {
        guard let safari = presentedSafari, safari.presentingViewController != nil else { return }
        onDismiss = nil
        safari.dismiss(animated: true) { [weak self] in
            self?.presentedSafari = nil
        }
    }
}

extension OfferSafariCoordinator: @preconcurrency SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        fireOnce()
    }
}

extension OfferSafariCoordinator: @preconcurrency UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        fireOnce()
    }
}
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
    @State private var contentHeight: CGFloat = 180
    @State private var checkoutURL: URL?
    @State private var hasApplePay = false

    @StateObject private var preloader = MigrationCheckoutPreloader()
    @State private var preloadTriggered = false
    /// True when performing a web-to-web upgrade (no WebView, just a spinner).
    @State private var webToWebInProgress = false

    #if os(iOS)
    /// Retains the `SFSafariViewController` delegate so we receive the
    /// `safariViewControllerDidFinish` callback for resetting `ctaTapped`.
    /// Stored as `@State` to survive view redraws while the sheet is open.
    @State private var safariCoordinator = OfferSafariCoordinator()
    #endif

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

    /// Apple-Pay-only mode: when true, native PassKit availability supersedes the
    /// JS-bridge `hasApplePay` signal for CTA / banner-visibility decisions.
    /// Reads through `ZeroSettle.shared.isApplePayOnly`, which resolves the
    /// backend `remoteConfig.checkout.paymentMethods` (and, in DEBUG builds,
    /// auto-resolves to `true` while ``ApplePayAvailability/debugStateOverride``
    /// is non-nil so the test flow can exercise the Apple-Pay-only branch).
    private var applePayOnlyMode: Bool {
        ZeroSettle.shared.isApplePayOnly
    }

    /// Pre-flight outcome for the current Apple-Pay-only / availability /
    /// behavior triple. Drives both the outer banner-hide decision and the
    /// inner CTA branching via `applePayPreflight.bannerDisplay`.
    private var applePayPreflight: ApplePayPreflightGate.Outcome {
        // Reads `state` directly on the @Observable singleton; SwiftUI tracks
        // the access during body evaluation and re-renders on transitions.
        ApplePayPreflightGate.evaluate(
            isApplePayOnly: applePayOnlyMode,
            state: ZeroSettle.shared.applePayAvailability.state,
            behavior: ZeroSettle.shared.resolvedApplePaySetupBehavior
        )
    }

    // MARK: - Init

    /// Creates a new offer tip view that reads the active user from the SDK.
    ///
    /// Call ``ZeroSettle/identify(_:)`` once at app launch before constructing
    /// this view. The view sources its ``ZSOfferManager`` from
    /// ``ZeroSettle/offerManager(stripeCustomerId:)``. If `identify(_:)` hasn't
    /// run yet, the manager stays in ``ZSOfferManager/State/loading`` and the
    /// view's body returns an empty placeholder until identification completes.
    ///
    /// - Parameters:
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
        stripeCustomerId: String? = nil,
        backgroundColor: Color = .black,
        titleFont: Font? = nil,
        bodyFont: Font? = nil,
        ctaFont: Font? = nil,
        borderColor: Color? = nil,
        onEvent: ((Event) -> Void)? = nil
    ) {
        self.stripeCustomerId = stripeCustomerId
        self.backgroundColor = backgroundColor
        self.titleFont = titleFont
        self.bodyFont = bodyFont
        self.ctaFont = ctaFont
        self.borderColor = borderColor
        self.onEvent = onEvent

        // `offerManager(stripeCustomerId:)` is non-throwing and eager — returns
        // a single shared instance regardless of identify state. If identify
        // hasn't run, the manager starts in `.loading` with empty userId; the
        // SDK calls its internal `setActiveUserId(_:)` when identify completes,
        // and `@ObservedObject` re-renders this view automatically.
        _manager = ObservedObject(
            wrappedValue: ZeroSettle.shared.offerManager(stripeCustomerId: stripeCustomerId)
        )
    }

    /// Creates a new offer tip view with an explicit user identifier.
    ///
    /// - Important: Deprecated. Call ``ZeroSettle/identify(_:)`` once at app
    ///   launch, then use the no-userId initializer instead. Direct construction
    ///   with `userId:` bypasses the SDK's identity tracking.
    @available(*, deprecated, message: "Call ZeroSettle.shared.identify(_:) once at app launch, then construct OfferTipView() without a userId. Will be removed in ZeroSettleKit 2.0.")
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
        // Belt-and-braces: pre-populate the SDK's active user from the legacy
        // param so callers that haven't yet adopted `identify(_:)` continue
        // working. Then delegate to the canonical init.
        ZeroSettle.shared.setActiveUserId(userId)
        self.init(
            stripeCustomerId: stripeCustomerId,
            backgroundColor: backgroundColor,
            titleFont: titleFont,
            bodyFont: bodyFont,
            ctaFont: ctaFont,
            borderColor: borderColor,
            onEvent: onEvent
        )
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
                if applePayPreflight.bannerDisplay == .hide {
                    // Apple-Pay-only merchant + (device cannot do Apple Pay) OR
                    // (setup required AND dev opted into .delegateToApp). Hide
                    // the banner; warning logged once on transition by
                    // ApplePayAvailability for the .unavailable case.
                    Color.clear.frame(height: 0)
                } else {
                    offerCardView
                }

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
            #if os(iOS)
            // Dismiss any presented browser checkout sheet so the success view
            // isn't hidden underneath it. UL callback / programmatic transitions
            // don't auto-dismiss SFSafariViewController.
            if newState != .presented {
                safariCoordinator.dismissIfPresented()
            }
            #endif
            // Failure path (poll detected `.failed`) bounces back to .eligible —
            // unstick the CTA so the user can retry.
            if newState == .eligible {
                ctaTapped = false
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
        // `userId:` is omitted: the modifier reads from `ZeroSettle.shared`'s
        // active user (set by `identify(_:)`). Forwarding our (possibly nil)
        // stored `userId` would just push redundant context.
        .checkoutSheet(
            item: $sheetCheckoutProduct,
            onPresent: { ctaTapped = false }
        ) { result in
            switch result {
            case .success(let txn):
                Task {
                    ZSLogger.info("[OfferTipView] Sheet checkout succeeded, calling markCheckoutSucceeded. state=\(manager.state) txn=\(txn.id)", category: .migration)
                    await manager.markCheckoutSucceeded(transactionId: txn.id)
                    ZSLogger.info("[OfferTipView] After markCheckoutSucceeded: state=\(manager.state) ctaTapped=\(ctaTapped)", category: .migration)
                    ctaTapped = false
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
        .alert(
            "Demo Mode",
            isPresented: Binding(
                get: { manager.showDemoModeAlert },
                set: { if !$0 { manager.dismissDemoModeAlert() } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(
                "Checkout is disabled while demoMode is active to prevent real charges. "
                + "Set ZSOfferManager.demoMode = .off and complete a StoreKit "
                + "sandbox purchase to test checkout end-to-end."
            )
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
                    if applePayPreflight.bannerDisplay == .showSetupCTA {
                        ctaButton(
                            label: ApplePayCopy.setupCTA,
                            accessibilityHint: "Opens the system Wallet to add a card for Apple Pay",
                            action: { ZeroSettle.shared.presentApplePaySetup() }
                        )
                    } else {
                        ctaButton(
                            label: display?.offerCtaOrDefault(defaultOfferCta) ?? defaultOfferCta,
                            accessibilityHint: "Opens the checkout to switch to direct billing",
                            action: handleCtaTapped
                        )
                    }
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
                        onLoaded: { },
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
                        },
                        onCheckoutFailure: { failure in
                            handleCheckoutFailure(failure)
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
        ZSLogger.info("[OfferTipView] handleCtaTapped: state=\(manager.state) upgradeType=\(manager.offerData?.upgradeType?.rawValue ?? "nil") checkoutPresentation=\(manager.offerData?.checkoutPresentation?.rawValue ?? "nil")", category: .migration)
        manager.present()
        ZSLogger.info("[OfferTipView] after present(): state=\(manager.state)", category: .migration)

        // If present() didn't transition to .presented (demo-mode gate fired,
        // or any other short-circuit), abort — don't initiate any checkout.
        guard manager.state == .presented else {
            ctaTapped = false
            return
        }

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
        case .safariVC:
            startBrowserCheckout(.safariVC)
            return
        case .safari:
            startBrowserCheckout(.safari)
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
        sheetCheckoutProduct = product
    }

    private func startWebViewCheckout() {
        let iap = ZeroSettle.shared
        let checkoutType = iap.checkoutType

        switch checkoutType {
        case .webView, .nativePay:
            startInlineWebViewCheckout()
        case .safari, .safariVC:
            startBrowserCheckout(checkoutType)
        }
    }

    private func startInlineWebViewCheckout() {
        Task {
            ZSLogger.info("[OfferTipView] startInlineWebViewCheckout: preloader.isReady=\(preloader.isReady) checkoutURL=\(checkoutURL != nil) state=\(manager.state)", category: .migration)

            // Fastest path: WebView already loaded (re-expanding after minimize)
            if checkoutURL != nil {
                ZSLogger.info("[OfferTipView] re-expanding existing WebView", category: .migration)
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded = true
                }
                return
            }

            // Fast path: preloader has URL and WebView ready
            if preloader.isReady, let url = await manager.preloadCheckout(stripeCustomerId: stripeCustomerId) {
                ZSLogger.info("[OfferTipView] using preloaded checkout URL", category: .migration)
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

            // Slow path: preloader missed (e.g., app launched too recently
            // or preload disabled). Hit the backend now to create the
            // Transaction row + checkout URL. The actual Stripe Intent
            // (PI / SI / Subscription) is still deferred until the user
            // submits payment in the WebView — this call doesn't touch
            // Stripe.
            ZSLogger.info("[OfferTipView] slow path: fetching checkout URL on-demand (no Stripe call)", category: .migration)
            let url = await manager.startCheckout(stripeCustomerId: stripeCustomerId)
            ZSLogger.info("[OfferTipView] startCheckout returned url=\(url != nil) state=\(manager.state)", category: .migration)
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

    #if os(iOS)
    /// Suspend until the app's next foreground transition. Used by the
    /// external-Safari checkout path to detect when the user has returned
    /// from Safari (with or without completing payment).
    @MainActor
    private static func waitForAppForeground() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                cont.resume()
            }
        }
    }
    #endif

    /// Browser-based checkout. `.safari` opens the system Safari app;
    /// `.safariVC` presents `SFSafariViewController` in-app as a slide-up sheet.
    /// Always requests the `browser` checkout template — the `native` template
    /// targets `WKWebView` with a `messageHandlers` bridge and only works via
    /// fallback paths when opened in standalone Safari.
    private func startBrowserCheckout(_ presentation: CheckoutType) {
        Task { @MainActor in
            guard manager.offerData != nil else {
                ctaTapped = false
                return
            }

            let url = await manager.startCheckout(
                stripeCustomerId: stripeCustomerId,
                checkoutMode: .browser
            )
            guard let checkoutURL = url else {
                ctaTapped = false
                return
            }

            #if os(iOS)
            if presentation == .safari {
                await UIApplication.shared.open(checkoutURL)
                // Poll so the manager advances when the user returns to the
                // app after paying — `processCheckoutCallback` won't do it.
                manager.startCheckoutCompletionPoll()
                // External Safari has no dismissal callback; if the user
                // returns without paying, release the .presented lock so
                // the CTA becomes tappable again. The brief delay gives a
                // successful UL callback / poll iteration time to advance
                // the state first — if it does, this is a no-op.
                Task { @MainActor [manager] in
                    await Self.waitForAppForeground()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if manager.state == .presented {
                        manager.releasePendingCheckout()
                    }
                }
                return
            }

            guard let topVC = SafariPresentation.topViewController() else {
                // No foreground-active scene — fall back to the system Safari app.
                await UIApplication.shared.open(checkoutURL)
                manager.startCheckoutCompletionPoll()
                return
            }

            let config = SFSafariViewController.Configuration()
            config.barCollapsingEnabled = false
            let safari = SFSafariViewController(url: checkoutURL, configuration: config)
            safari.preferredBarTintColor = UIColor(backgroundColor)
            safari.preferredControlTintColor = .white
            safari.applyZSPageSheetPresentation()
            safari.delegate = safariCoordinator
            safari.presentationController?.delegate = safariCoordinator
            safariCoordinator.presentedSafari = safari
            safariCoordinator.onDismiss = { [manager] in
                // User dismissed without completing checkout — release the
                // .presented lock so the CTA is tappable again. Skip on the
                // success path: the UL callback already advanced the state.
                // The view's `onChange(of: manager.state)` resets `ctaTapped`
                // when state lands on `.eligible`.
                manager.releasePendingCheckout()
            }
            topVC.present(safari, animated: true)
            // Poll the transaction status. SafariVC can't intercept Stripe's
            // redirect to fire UL, and the UL callback path doesn't transition
            // the manager state. Polling drives `markCheckoutSucceeded` on
            // success and reverts to `.eligible` on failure — both handled by
            // the view's `onChange(of: manager.state)` observer (sheet dismiss,
            // CTA reset).
            manager.startCheckoutCompletionPoll()
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
            // Don't override contentHeight here — the body.scrollHeight
            // ResizeObserver on the inline WebView already drives accurate
            // height. Hard-coding applePayCollapsedHeight (180) inflates
            // the card when only Apple Pay is rendered (no card row), and
            // because the ResizeObserver only fires on actual body resizes,
            // a single override above the measured value never recovers.
            hasApplePay = true
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

    private func handleCheckoutFailure(_ failure: CheckoutFailure) {
        // Reset UI state so the CTA reappears for retry.
        withAnimation(.easeInOut(duration: 0.25)) {
            isExpanded = false
            contentHeight = Self.collapsedHeight
            checkoutURL = nil
        }
        ctaTapped = false

        #if canImport(ZeroSettleCore)
        ZSLogger.error(
            "[OfferTipView] checkout_load_failure: \(failure.description)",
            category: .migration
        )
        #endif
    }

    private func handleCheckoutSuccess(transactionId: String?) {
        ZSLogger.info("[OfferTipView] handleCheckoutSuccess: txn=\(transactionId ?? "nil") state=\(manager.state) ctaTapped=\(ctaTapped) isExpanded=\(isExpanded)", category: .migration)
        withAnimation(.easeInOut(duration: 0.25)) {
            isExpanded = false
            contentHeight = Self.collapsedHeight
            checkoutURL = nil
        }
        Task {
            await manager.markCheckoutSucceeded(transactionId: transactionId)
            ZSLogger.info("[OfferTipView] after markCheckoutSucceeded: state=\(manager.state) needsAppleCancel=\(manager.needsAppleCancel)", category: .migration)
            ctaTapped = false
            onEvent?(.checkoutCompleted)
            if manager.state == .completed {
                transitionToCompleted()
            }
            // .accepted state renders acceptedCardView with "Cancel Apple Billing" button
        }
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            confettiTrigger += 1
        }

        onEvent?(.offerCompleted)

        // Auto-dismiss after 5 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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
