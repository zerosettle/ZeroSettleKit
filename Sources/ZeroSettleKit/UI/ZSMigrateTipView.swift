import SwiftUI
import UIKit
import StoreKit
import WebKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Expandable Web Billing Tip View
public struct MigrationTipView: View {

    /// Lifecycle events emitted by ``MigrationTipView``.
    ///
    /// Use these with the ``onEvent`` callback to track user progression
    /// through the migration flow without polling ``ZSMigrationManager/state``.
    public enum Event: Sendable {
        /// The user tapped the main CTA button to begin checkout.
        case ctaTapped
        /// The web checkout completed successfully. The user now has a web
        /// entitlement but their Apple subscription is still active.
        case checkoutCompleted
        /// The user opened Apple's subscription-management sheet to cancel
        /// their Apple billing.
        case appleSubscriptionManagementOpened
        /// The full migration flow is finished — web checkout succeeded **and**
        /// the Apple subscription-management sheet was shown.
        case migrationCompleted
        /// The view was dismissed (close button, auto-dismiss after completion,
        /// or the user became ineligible).
        case dismissed
    }

    let userId: String
    let stripeCustomerId: String?
    let backgroundColor: Color
    let titleFont: Font?
    let bodyFont: Font?
    let ctaFont: Font?
    let borderColor: Color?
    let onEvent: ((Event) -> Void)?

    @ObservedObject private var manager: ZSMigrationManager

    // MARK: - UI-only State

    @State private var isExpanded = false
    @State private var ctaTapped = false
    @State private var webViewLoaded = false
    @State private var contentHeight: CGFloat = 180
    @State private var showCongratulations = false
    @State private var checkingCancellation = false
    @State private var confettiTrigger = 0
    @State private var checkoutURL: URL?
    @State private var hasApplePay = false

    static let collapsedHeight: CGFloat = 180
    static let applePayCollapsedHeight: CGFloat = 180
    static let applePayCardExpandedHeight: CGFloat = 820
    static let noApplePayExpandedHeight: CGFloat = 800
    static let noApplePayCollapsedHeight: CGFloat = 90

    /// Creates a new migrate tip view.
    ///
    /// Uses the shared ``ZSMigrationManager`` from ``ZeroSettle/shared/migrationManager``
    /// (created during ``ZeroSettle/bootstrap(userId:)``). Falls back to creating a local
    /// instance if bootstrap hasn't run yet.
    ///
    /// - Parameters:
    ///   - userId: The user identifier passed to the checkout backend.
    ///   - stripeCustomerId: Optional existing Stripe Customer ID (`cus_xxx`) to attach the checkout to. When `nil`, the backend creates a new customer.
    ///   - backgroundColor: The background color for the view. Defaults to `.black`.
    ///   - titleFont: Optional custom font for title text. When `nil`, the default system bold font is used.
    ///   - bodyFont: Optional custom font for body/message text. When `nil`, the default system font is used.
    ///   - ctaFont: Optional custom font for CTA button text. When `nil`, the default system bold font is used.
    ///   - borderColor: Optional border color applied as a rounded rectangle stroke on card views. When `nil`, no border is drawn.
    ///   - onEvent: Optional closure invoked when a lifecycle ``Event`` occurs (CTA tap, checkout completion, migration completion, dismissal, etc.).
    /// - Note: Free trial days are automatically calculated based on when the user's current StoreKit subscription expires.
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
        // Always use the shared singleton manager. migrationManager(for:) guarantees
        // a single instance — whether bootstrap ran first or the view was created first.
        let mgr = ZeroSettle.shared.migrationManager(for: userId, stripeCustomerId: stripeCustomerId)
        _manager = ObservedObject(wrappedValue: mgr)
        ZSLogger.info("[MigrateTipView] init — manager.state=.\(mgr.state), offerData=\(mgr.offerData != nil ? "present" : "nil"), userId=\(userId)", category: .migration)
    }

    /// Backward-compatible convenience that maps the legacy `onDismiss` closure to
    /// the new ``onEvent`` callback, firing only on ``Event/dismissed``.
    @available(*, deprecated, renamed: "init(userId:backgroundColor:titleFont:bodyFont:ctaFont:borderColor:onEvent:)")
    public init(
        userId: String,
        backgroundColor: Color = .black,
        titleFont: Font? = nil,
        bodyFont: Font? = nil,
        ctaFont: Font? = nil,
        borderColor: Color? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.init(
            userId: userId,
            backgroundColor: backgroundColor,
            titleFont: titleFont,
            bodyFont: bodyFont,
            ctaFont: ctaFont,
            borderColor: borderColor,
            onEvent: { event in
                if case .dismissed = event { onDismiss() }
            }
        )
    }

    // MARK: - Convenience

    /// The savings percentage for the migration target product, sent by the backend.
    private var discountPercent: Int {
        manager.offerData?.prompt.discountPercent ?? 0
    }

    // MARK: - Body

    public var body: some View {
        let _ = ZSLogger.info("[MigrateTipView] body evaluated — state=.\(manager.state), offerData=\(manager.offerData != nil ? "present(productId=\(manager.offerData!.prompt.productId), discount=\(manager.offerData!.prompt.discountPercent)%)" : "nil"), isExpanded=\(isExpanded)", category: .migration)
        Group {
            switch manager.state {
            case .loading:
                let _ = ZSLogger.debug("[MigrateTipView] Rendering .loading — showing clear placeholder", category: .migration)
                Color.clear.frame(height: 0)

            case .ineligible:
                let _ = ZSLogger.debug("[MigrateTipView] Rendering .ineligible — showing clear placeholder", category: .migration)
                Color.clear.frame(height: 0)

            case .dismissed:
                let _ = ZSLogger.debug("[MigrateTipView] Rendering .dismissed — showing EmptyView", category: .migration)
                EmptyView()

            case .eligible, .presented:
                let _ = ZSLogger.debug("[MigrateTipView] Rendering .\(manager.state) — showing offerCardView", category: .migration)
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
            ZSLogger.info("[MigrateTipView] state changed → .\(newState)", category: .migration)
            if newState == .dismissed {
                onEvent?(.dismissed)
            }
        }
    }

    // MARK: - Sub-views

    /// The initial offer card with header + CTA / webview.
    private var offerCardView: some View {
        VStack(spacing: 0) {
            // Tip header
            headerView(
                icon: { Text("🎁").font(.largeTitle) },
                title: "Thanks for being with us!",
                message: manager.offerData?.prompt.message
                    ?? (discountPercent > 0
                        ? "Switch to direct billing and get \(discountPercent)% off forever. Same features, fewer platform fees, and we pass the savings onto you."
                        : "Switch to direct billing. Same features, fewer platform fees."),
                showCloseButton: true
            )

            // CTA button (hidden when webview is expanded)
            if !isExpanded {
                if ctaTapped {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding(.bottom, 16)
                } else {
                    Button(action: { ctaTapped = true; startCheckout() }) {
                        HStack(spacing: 8) {
                            if manager.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: backgroundColor))
                                    .scaleEffect(0.8)
                            }
                            Text(manager.isLoading ? "" : (manager.offerData?.prompt.ctaText ?? (discountPercent > 0 ? "Save \(discountPercent)% Forever" : "Switch Now")))
                                .font(ctaFont ?? .body.weight(.bold))
                                .foregroundColor(backgroundColor)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(Capsule())
                    }
                    .disabled(manager.isLoading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }

            // Inline WebView (only when expanded)
            if isExpanded, let checkoutURLValue = checkoutURL {
                VStack(spacing: 8) {
                    CheckoutWebView(
                        url: checkoutURLValue,
                        backgroundColor: UIColor(backgroundColor),
                        onLoaded: {
                            webViewLoaded = true
                        },
                        onPaymentMethodChanged: { paymentMethod in
                            switch paymentMethod {
                            case "apple_pay_detected":
                                hasApplePay = true
                                print("📐 [MigrateTip] apple_pay_detected → applePayCollapsed (\(Self.applePayCollapsedHeight))")
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    contentHeight = Self.applePayCollapsedHeight
                                }
                            case "card_expanded":
                                let newHeight = hasApplePay
                                    ? Self.applePayCardExpandedHeight
                                    : Self.noApplePayExpandedHeight
                                print("📐 [MigrateTip] card_expanded (hasApplePay=\(hasApplePay)) → \(newHeight)")
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    contentHeight = newHeight
                                }
                            case "card_collapsed":
                                let newHeight = hasApplePay
                                    ? Self.applePayCollapsedHeight
                                    : Self.noApplePayCollapsedHeight
                                print("📐 [MigrateTip] card_collapsed (hasApplePay=\(hasApplePay)) → \(newHeight)")
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    contentHeight = newHeight
                                }
                            default:
                                print("📐 [MigrateTip] unknown state '\(paymentMethod)' → collapsedHeight (\(Self.collapsedHeight))")
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    contentHeight = Self.collapsedHeight
                                }
                            }
                        },
                        onCheckoutSuccess: { transactionId in
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
                    )
                    .frame(height: contentHeight)
                    .cornerRadius(12)
                    .padding(.horizontal, 12)

                    Text("You won't be billed until the end of your current cycle. Cancel anytime.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .padding(.bottom, 16)
                .zIndex(-1)
                .transition(.opacity)
            }
        }
        .background(backgroundColor)
        .cornerRadius(16)
        .overlay(
            Group {
                if let borderColor {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 2)
                }
            }
        )
    }

    /// Card shown after checkout succeeds with "Cancel Apple Billing" CTA.
    private var acceptedCardView: some View {
        VStack(spacing: 0) {
            headerView(
                icon: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .stroke(.green, lineWidth: 3)
                            )
                        Image(systemName: "checkmark")
                            .font(.title2.weight(.bold))
                            .foregroundColor(.green)
                    }
                },
                title: "Thanks for switching!",
                message: "The last step is to cancel your Apple billing! Your card won't be charged until the end of your last Apple billing cycle. Pro features will continue uninterrupted.",
                showCloseButton: false
            )

            Button(action: {
                Task {
                    await openSubscriptionManagement()
                }
            }) {
                Text("Cancel Apple Billing")
                    .font(ctaFont ?? .body.weight(.bold))
                    .foregroundColor(backgroundColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(backgroundColor)
        .cornerRadius(16)
        .overlay(
            Group {
                if let borderColor {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 2)
                }
            }
        )
    }

    /// Loading spinner shown while checking if Apple subscription was cancelled.
    private var checkingCancellationView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Checking subscription status...")
                .font(bodyFont ?? .subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(backgroundColor)
        .cornerRadius(16)
        .overlay(
            Group {
                if let borderColor {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 2)
                }
            }
        )
    }

    /// Card shown after subscription management with confetti.
    private var congratulationsCardView: some View {
        VStack(spacing: 0) {
            headerView(
                icon: { Text("🎉").font(.largeTitle) },
                title: "Congratulations!",
                message: "You are now saving \(discountPercent)% forever.",
                showCloseButton: false
            )
        }
        .background(backgroundColor)
        .cornerRadius(16)
        .overlay(
            Group {
                if let borderColor {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 2)
                }
            }
        )
    }

    /// Reusable header with icon, title, message, and optional close button.
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
                                manager.dismiss()
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                        }
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
        .confettiCannon(trigger: $confettiTrigger, num: 50, openingAngle: Angle(degrees: 0), closingAngle: Angle(degrees: 360), radius: 200)
    }

    // MARK: - Actions

    @MainActor
    private func openSubscriptionManagement() async {
        // Show the Apple manage subscription sheet
        // showAppleSubscriptionManagement opens the sheet, then after dismiss
        // checks StoreKit status and updates backend — we show a spinner during that
        withAnimation(.easeInOut(duration: 0.2)) {
            checkingCancellation = true
        }
        await manager.showAppleSubscriptionManagement()
        onEvent?(.appleSubscriptionManagementOpened)
        withAnimation(.easeInOut(duration: 0.2)) {
            checkingCancellation = false
        }

        guard manager.state == .completed else { return }

        // Show congratulations with confetti
        withAnimation(.easeInOut(duration: 0.3)) {
            showCongratulations = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.confettiTrigger += 1
        }

        onEvent?(.migrationCompleted)

        // Auto-dismiss after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                manager.dismiss()
            }
        }
    }

    private func startCheckout() {
        onEvent?(.ctaTapped)
        let iap = ZeroSettle.shared
        let checkoutType = iap.checkoutType

        switch checkoutType {
        case .webView, .nativePay:
            startWebViewCheckout()
        case .safari, .safariVC:
            startBrowserCheckout()
        }
    }

    private func startWebViewCheckout() {
        Task {
            if let baseURL = ZeroSettle.shared.effectiveBaseURL {
                let paymentIntentsURL = baseURL.appendingPathComponent("iap/payment-intents/")
                ZSLogger.info("[MigrateTipView] Stripe payment intents URL: \(paymentIntentsURL.absoluteString)", category: .migration)
            }
            let url = await manager.startCheckout()
            if let url {
                checkoutURL = url
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded = true
                }
            } else {
                ctaTapped = false
            }
        }
    }

    private func startBrowserCheckout() {
        guard let offerData = manager.offerData else { return }
        manager.present()

        Task { @MainActor in
            let iap = ZeroSettle.shared
            do {
                try await iap.purchase(productId: offerData.activeStoreKitProductId, userId: userId)
                await manager.markCheckoutSucceeded()
                onEvent?(.checkoutCompleted)
            } catch {
                // Stay in presented state; user can retry
            }
        }
    }
}

// MARK: - Checkout WebView (loads on-demand with accordion detection)
struct CheckoutWebView: UIViewRepresentable {
    let url: URL
    let backgroundColor: UIColor
    let onLoaded: () -> Void
    let onPaymentMethodChanged: (String) -> Void
    let onCheckoutSuccess: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            backgroundColor: backgroundColor,
            onLoaded: onLoaded,
            onPaymentMethodChanged: onPaymentMethodChanged,
            onCheckoutSuccess: onCheckoutSuccess
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        // Add script message handlers for payment method changes, checkout completion, and debug logs
        configuration.userContentController.add(context.coordinator, name: "paymentMethodChanged")
        configuration.userContentController.add(context.coordinator, name: "checkoutComplete")
        configuration.userContentController.add(context.coordinator, name: "debugLog")

        // IMPORTANT:
        // The Stripe/ZeroSettle checkout UI may render inside an iframe. `evaluateJavaScript`
        // in `didFinish` only runs on the main frame, which is why we were seeing:
        //   btn=nil panel=nil ...
        // even though the DOM you pasted clearly exists.
        //
        // So we inject as a WKUserScript with `forMainFrameOnly: false` to run in *all frames*.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: context.coordinator.buildInjectedJavaScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor
        webView.scrollView.isScrollEnabled = false
        webView.layer.cornerRadius = 12
        webView.clipsToBounds = true
        webView.navigationDelegate = context.coordinator

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No updates needed
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let backgroundColor: UIColor
        let onLoaded: () -> Void
        let onPaymentMethodChanged: (String) -> Void
        let onCheckoutSuccess: (String?) -> Void
        private var hasCompleted = false

        init(
            backgroundColor: UIColor,
            onLoaded: @escaping () -> Void,
            onPaymentMethodChanged: @escaping (String) -> Void,
            onCheckoutSuccess: @escaping (String?) -> Void
        ) {
            self.backgroundColor = backgroundColor
            self.onLoaded = onLoaded
            self.onPaymentMethodChanged = onPaymentMethodChanged
            self.onCheckoutSuccess = onCheckoutSuccess
        }

        // Handle messages from JavaScript
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "debugLog" {
                // Intentionally ignore verbose WebView logging.
            } else if message.name == "paymentMethodChanged", let paymentMethod = message.body as? String {
                DispatchQueue.main.async {
                    self.onPaymentMethodChanged(paymentMethod)
                }
            } else if message.name == "checkoutComplete", let body = message.body as? [String: Any] {
                let action = body["action"] as? String ?? ""
                let success = body["success"] as? Bool ?? false

                if action == "expandSheet" {
                    DispatchQueue.main.async {
                        self.onPaymentMethodChanged("card_expanded")
                    }
                } else if action == "collapseSheet" {
                    DispatchQueue.main.async {
                        self.onPaymentMethodChanged("card_collapsed")
                    }
                } else if action == "complete" || success {
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    let transactionId = body["transaction_id"] as? String
                    DispatchQueue.main.async {
                        self.onCheckoutSuccess(transactionId)
                    }
                }
            }
        }

        private func rgbString() -> (r: Int, g: Int, b: Int) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return (Int(red * 255), Int(green * 255), Int(blue * 255))
        }

        func buildInjectedJavaScript() -> String {
            let rgb = rgbString()
            let r = rgb.r, g = rgb.g, b = rgb.b

            // NOTE: This script is idempotent (guarded) because it may run multiple times
            // across navigations/frames.
            return """
            (function() {
              if (window.__divecastPaymentDetectionInstalled) { return; }
              window.__divecastPaymentDetectionInstalled = true;

              function log(msg) {
                try {
                  var href = (window.location && window.location.href) ? window.location.href : '(no-href)';
                  window.webkit.messageHandlers.debugLog.postMessage('[frame=' + href + '] ' + msg);
                } catch (e) {}
              }

              function safeStr(x) { try { return String(x); } catch (e) { return '[unstringifiable]'; } }

              log('Installing payment method detection (all-frames user script).');

              // Inject custom CSS (ok if duplicated across frames)
              // Detect which Stripe sub-frame we're inside
              var isStripePaymentFrame = window.location.href.indexOf('js.stripe.com') !== -1
                  && window.location.href.indexOf('componentName=payment') !== -1;
              var isStripeExpressCheckoutFrame = window.location.href.indexOf('js.stripe.com') !== -1
                  && window.location.href.indexOf('componentName=expressCheckout') !== -1;

              try {
                var style = document.createElement('style');
                if (isStripePaymentFrame) {
                  // Inside the Stripe payment iframe — force light background
                  style.innerHTML = `
                    html, body {
                      background-color: #f2f2f6 !important;
                      background: #f2f2f6 !important;
                    }
                  `;
                } else if (isStripeExpressCheckoutFrame) {
                  // Inside the Stripe express checkout iframe — show plain Apple Pay button
                  style.innerHTML = `
                    .p-ApplePayButton--subscribe {
                      -apple-pay-button-type: plain !important;
                    }
                  `;
                } else {
                  style.innerHTML = `
                    html, body, .payment-sheet, .checkout-container, .container, #root, #app, main {
                      background-color: rgb(\(r), \(g), \(b)) !important;
                      background: rgb(\(r), \(g), \(b)) !important;
                    }

                  /* Hide loading checkout spinner */
                  #loading-state,
                  .loading-container,
                  .loading-spinner,
                  .loading-text {
                    display: none !important;
                    visibility: hidden !important;
                  }

                  /* Hide embedded close/back buttons inside checkout */
                  .close-btn,
                  button.close-btn {
                    display: none !important;
                    visibility: hidden !important;
                    opacity: 0 !important;
                    pointer-events: none !important;
                  }

                  /* Style submit button with green color */
                  .submit-btn,
                  #submit,
                  button[type="submit"] {
                    background-color: #34C759 !important;
                    background: #34C759 !important;
                  }

                  .submit-btn:hover,
                  #submit:hover,
                  button[type="submit"]:hover {
                    background-color: #30B350 !important;
                    background: #30B350 !important;
                  }

                  /* Style loading text white */
                  .loading-text {
                    color: white !important;
                  }

                  /* Style "or" divider white */
                  .or-divider,
                  #or-divider,
                  .or-divider span {
                    color: white !important;
                    border-color: rgba(255, 255, 255, 0.3) !important;
                  }
                  .or-divider::before,
                  .or-divider::after,
                  #or-divider::before,
                  #or-divider::after {
                    background-color: rgba(255, 255, 255, 0.3) !important;
                  }

                  /* Style "Secured by Stripe" and footer text white */
                  [class*="secured"],
                  [class*="stripe-badge"],
                  [class*="footer"],
                  [class*="branding"],
                  .stripe-secured,
                  .powered-by-stripe,
                  .secure-badge,
                  .security-text {
                    color: white !important;
                    fill: white !important;
                  }
                  [class*="secured"] span,
                  [class*="footer"] span,
                  [class*="branding"] span {
                    color: white !important;
                  }
                `;
                }
                document.head && document.head.appendChild(style);
              } catch (e) {
                log('CSS inject failed: ' + safeStr(e));
              }

              function findButton(dataValue) {
                return document.querySelector('.p-AccordionButton[data-value="' + dataValue + '"]')
                    || document.querySelector('[data-value="' + dataValue + '"]');
              }

              function isButtonExpanded(dataValue) {
                var btn = findButton(dataValue);
                if (btn) {
                  return btn.getAttribute('aria-expanded') === 'true';
                }
                return false;
              }

              var lastPaymentMethod = null;

              function computeActivePaymentMethod() {
                // Check Stripe accordion buttons (only present when Apple Pay is available)
                if (isButtonExpanded('card')) {
                  return 'card';
                }
                if (isButtonExpanded('apple_pay')) {
                  return 'apple_pay';
                }
                return null;
              }

              function report(reason) {
                var applePayBtn = findButton('apple_pay');
                var cardBtn = findButton('card');

                var applePayState = applePayBtn ? applePayBtn.getAttribute('aria-expanded') : null;
                var cardState = cardBtn ? cardBtn.getAttribute('aria-expanded') : null;

                var paymentMethod = computeActivePaymentMethod();

                log('[report:' + reason + '] apple_pay=' + safeStr(applePayState)
                  + ' card=' + safeStr(cardState)
                  + ' => paymentMethod=' + safeStr(paymentMethod));

                // null means no accordion buttons found (no-Apple-Pay case);
                // that path is handled by expandSheet/collapseSheet instead.
                if (paymentMethod === null) { return; }
                if (lastPaymentMethod === paymentMethod) { return; }
                lastPaymentMethod = paymentMethod;

                log('Sending paymentMethodChanged -> ' + safeStr(paymentMethod));
                try { window.webkit.messageHandlers.paymentMethodChanged.postMessage(paymentMethod); } catch (e) {}
              }

              function isPaymentMethodTap(event) {
                var t = event && event.target ? event.target : null;
                if (!t || !t.closest) { return false; }
                return !!t.closest('[data-value="apple_pay"]') || !!t.closest('[data-value="card"]');
              }

              // Detect custom Apple Pay container (non-accordion checkout)
              // Supports both legacy #apple-pay-container and the new Express Checkout
              // Element layout where #express-checkout-container.visible holds Apple Pay.
              var applePayDetected = false;
              function detectCustomApplePay(reason) {
                if (applePayDetected) { return; }
                // Legacy: dedicated Apple Pay container
                var container = document.getElementById('apple-pay-container');
                if (container && container.classList.contains('visible')) {
                  applePayDetected = true;
                  log('[' + reason + '] Custom Apple Pay container detected.');
                  try { window.webkit.messageHandlers.paymentMethodChanged.postMessage('apple_pay_detected'); } catch (e) {}
                  return;
                }
                // New: Stripe Express Checkout Element (Apple Pay + Google Pay + Link)
                var expressContainer = document.getElementById('express-checkout-container');
                if (expressContainer && expressContainer.classList.contains('visible')) {
                  // Verify that the container actually rendered content (has a visible iframe)
                  var iframe = expressContainer.querySelector('iframe');
                  if (iframe && iframe.offsetHeight > 0) {
                    applePayDetected = true;
                    log('[' + reason + '] Express Checkout container with Apple Pay detected.');
                    try { window.webkit.messageHandlers.paymentMethodChanged.postMessage('apple_pay_detected'); } catch (e) {}
                  }
                }
              }

              // Initial probing (Stripe often hydrates late)
              setTimeout(function() { detectCustomApplePay('t+300ms'); report('t+300ms'); }, 300);
              setTimeout(function() { detectCustomApplePay('t+800ms'); report('t+800ms'); }, 800);
              setTimeout(function() { detectCustomApplePay('t+1500ms'); report('t+1500ms'); }, 1500);
              setTimeout(function() { detectCustomApplePay('t+3000ms'); report('t+3000ms'); }, 3000);

              // Tap detection: when a payment method is tapped, re-check after animation/hydration.
              document.addEventListener('click', function(e) {
                if (!isPaymentMethodTap(e)) { return; }
                log('Payment method tap detected (event delegation).');
                setTimeout(function() { report('tap+0ms'); }, 0);
                setTimeout(function() { report('tap+120ms'); }, 120);
                setTimeout(function() { report('tap+300ms'); }, 300);
                setTimeout(function() { report('tap+600ms'); }, 600);
              }, true);

              // Observe aria-expanded changes on any payment method button.
              var observer = new MutationObserver(function(muts) {
                for (var i = 0; i < muts.length; i++) {
                  var m = muts[i];
                  if (m.type === 'attributes' && m.attributeName === 'aria-expanded') {
                    var target = m.target;
                    var dataValue = target && target.getAttribute ? target.getAttribute('data-value') : null;
                    if (dataValue === 'apple_pay' || dataValue === 'card') {
                      log('Observed aria-expanded mutation on ' + dataValue + ' button.');
                      report('mutation:aria-expanded');
                      return;
                    }
                  }
                }
              });
              try {
                observer.observe(document.body, { subtree: true, attributes: true, attributeFilter: ['aria-expanded'] });
              } catch (e) {
                log('MutationObserver attach failed: ' + safeStr(e));
              }

              // Poll fallback
              setInterval(function() { report('poll'); }, 2000);

              log('Payment method detection installed.');
            })();
            """
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let host = (url.host ?? "").lowercased()
            let path = url.path.lowercased()
            let query = (url.query ?? "").lowercased()

            let isNewWindow = (navigationAction.targetFrame == nil)

            // Don't treat the main checkout URL as a universal link.
            let isCheckoutPage = host == "api.zerosettle.io" && path.hasPrefix("/elements/checkout")

            // ZeroSettle appears to use Universal Links for the app return.
            // In practice, the universal-link URL often includes a marker (in your entitlements you have `?mode=developer`).
            let looksLikeUniversalLinkReturn =
                host.hasSuffix("zerosettle.io")
                && !isCheckoutPage
                && (query.contains("mode=developer") || path.contains("success") || path.contains("complete") || path.contains("return"))

            if looksLikeUniversalLinkReturn {
                let looksLikeSuccess =
                    path.contains("success")
                    || path.contains("complete")
                    || query.contains("success")
                    || query.contains("succeed")
                    || query.contains("status=success")
                    || query.contains("status=succeeded")
                    || query.contains("result=success")
                    || query.contains("result=succeeded")

                if looksLikeSuccess {
                    guard !hasCompleted else {
                        decisionHandler(.cancel)
                        return
                    }
                    hasCompleted = true
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let transactionId = components?.queryItems?.first(where: { $0.name == "transaction_id" })?.value
                    DispatchQueue.main.async {
                        self.onCheckoutSuccess(transactionId)
                    }
                }

                // IMPORTANT:
                // Do NOT open externally (Safari). We only use this as a signal and keep the user in-app.
                decisionHandler(.cancel)
                return
            }

            // If something tries to open a new window (targetFrame == nil), open it externally.
            if isNewWindow {
                // Keep everything inside this WKWebView (avoid Safari).
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Script is injected via WKUserScript (all frames). We just mark loaded.
            onLoaded()
        }
    }
}
