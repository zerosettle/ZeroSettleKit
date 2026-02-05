import SwiftUI
import UIKit
import StoreKit
import WebKit

// MARK: - Expandable Web Billing Tip View
public struct ZSMigrateTipView: View {
    let backgroundColor: Color
    
    @State private var isExpanded = false
    @State private var isLoading = false
    @State private var webViewLoaded = false
    @State private var contentHeight: CGFloat = 220 // Default collapsed height
    @State private var checkoutSucceeded = false
    @State private var isDismissed = false
    @State private var showCongratulations = false
    @State private var confettiTrigger = 0
    @State private var checkoutURL: URL?
    @State private var checkoutError: Error?
    
    static let checkoutProductId = "divegeniusmonthly"
    static let collapsedHeight: CGFloat = 220
    static let applePayExpandedHeight: CGFloat = 352
    static let cardExpandedHeight: CGFloat = 690
    
    // MARK: - Persistence
    
    private static let dismissedKey = "com.zerosettle.migrateTipDismissed"
    
    /// Whether the migrate tip has been permanently dismissed (persisted across app launches).
    private static var isPermanentlyDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }
    
    /// Resets the migrate tip dismissed state, allowing it to be shown again.
    /// Use this for debugging purposes.
    public static func resetMigrateTipState() {
        isPermanentlyDismissed = false
    }
    
    /// Marks the migrate tip as permanently dismissed.
    private static func markAsPermanentlyDismissed() {
        isPermanentlyDismissed = true
    }
    
    /// Creates a new migrate tip view.
    /// - Parameter backgroundColor: The background color for the view.
    public init(backgroundColor: Color) {
        self.backgroundColor = backgroundColor
    }
    
    public var body: some View {
        if !isDismissed && !Self.isPermanentlyDismissed {
            VStack(spacing: 0) {
            // Tip header (always visible)
            HStack(alignment: .center, spacing: 12) {
                // Icon (vertically centered)
                if showCongratulations {
                    Text("🎉")
                        .font(.system(size: 44))
                } else if checkoutSucceeded {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .stroke(.green, lineWidth: 3)
                            )
                        Image(systemName: "checkmark")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.green)
                    }
                } else {
                    Text("🎁")
                        .font(.system(size: 44))
                }
                
                // Title + body text on the right
                VStack(alignment: .leading, spacing: 2) {
                    // Title row with close button
                    HStack(alignment: .top, spacing: 8) {
                        Text(showCongratulations ? "Congratulations!" : (checkoutSucceeded ? "Thanks for switching!" : "GRDEBUGThanks for being with us!"))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        
                        Spacer()
                        
                        // Close button (hidden during checkout success and congratulations states)
                        if !showCongratulations && !checkoutSucceeded {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isDismissed = true
                                    Self.markAsPermanentlyDismissed()
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .offset(y: -4)
                        }
                    }
                    
                    // Body text (full width)
                    Text(showCongratulations
                         ? "You are now saving 15% forever."
                         : (checkoutSucceeded
                            ? "The last step is to cancel your Apple billing! Your card won't be charged by DiveGenius until the end of your last Apple billing cycle. Pro features will continue uninterrupted."
                            : "Switch to direct billing and get 15% off DiveGenius Pro forever. Same features, fewer platform fees, and we pass the savings onto you."))
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .confettiCannon(trigger: $confettiTrigger, num: 50, openingAngle: Angle(degrees: 0), closingAngle: Angle(degrees: 360), radius: 200)
            
            // Show "Cancel Apple Billing" button after success (but not during congratulations)
            if checkoutSucceeded && !showCongratulations {
                Button(action: {
                    Task {
                        await openSubscriptionManagement()
                    }
                }) {
                    Text("Cancel Apple Billing")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(backgroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else if !isExpanded && !showCongratulations {
                Button(action: {
                    startCheckoutSession()
                }) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: backgroundColor))
                                .scaleEffect(0.8)
                        }
                        Text(isLoading ? "" : "Save 15% Forever")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(backgroundColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(Capsule())
                }
                .disabled(isLoading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            
            // Inline WebView (only when expanded)
            if isExpanded && !checkoutSucceeded, let checkoutURLValue = checkoutURL {
                VStack(spacing: 8) {
                    CheckoutWebView(
                        url: checkoutURLValue,
                        backgroundColor: UIColor(backgroundColor),
                        onLoaded: {
                            isLoading = false
                            webViewLoaded = true
                        },
                        onPaymentMethodChanged: { paymentMethod in
                            let newHeight: CGFloat
                            switch paymentMethod {
                            case "apple_pay":
                                newHeight = Self.applePayExpandedHeight
                            case "card":
                                newHeight = Self.cardExpandedHeight
                            default:
                                newHeight = Self.collapsedHeight
                            }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                contentHeight = newHeight
                            }
                        },
                        onCheckoutSuccess: { successURL in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isExpanded = false
                                isLoading = false
                                webViewLoaded = false
                                contentHeight = Self.collapsedHeight
                                checkoutSucceeded = true
                                checkoutURL = nil
                            }
                        }
                    )
                    .frame(height: contentHeight)
                    .cornerRadius(12)
                    .padding(.horizontal, 12)
                    
                    Text("You won't be billed until the end of your current cycle on January 31st. Cancel anytime.")
                        .font(.system(size: 12))
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
        }
    }
    
    @MainActor
    private func openSubscriptionManagement() async {
        print("📱 Opening Apple subscription management...")
        
        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                print("❌ No window scene available")
                return
            }
            try await AppStore.showManageSubscriptions(in: windowScene)
            print("✅ Subscription management sheet opened")
            
            // Show congratulations state with confetti after sheet dismisses
            withAnimation(.easeInOut(duration: 0.3)) {
                showCongratulations = true
            }
            
            // Trigger confetti
            confettiTrigger += 1
            
            // Auto-dismiss after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isDismissed = true
                    Self.markAsPermanentlyDismissed()
                }
            }
        } catch {
            print("❌ Failed to open subscription management: \(error)")
            print("   Error details: \(error.localizedDescription)")
        }
    }

    private func startCheckoutSession() {
        checkoutError = nil
        isLoading = true

        print("🧾 Creating checkout session (productId=\(Self.checkoutProductId))")

        Task {
            do {
                let backend = try getBackend()
                let session = try await backend.createCheckoutSession(productId: Self.checkoutProductId)
                
                await MainActor.run {
                    print("✅ Checkout session created. checkoutUrl=\(session.checkoutUrl.absoluteString)")
                    checkoutURL = session.checkoutUrl
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isExpanded = true
                    }
                }
            } catch {
                await MainActor.run {
                    checkoutError = error
                    isLoading = false
                    print("❌ Checkout session failed (productId=\(Self.checkoutProductId)): \(error)")
                }
            }
        }
    }

    private func getBackend() throws -> Backend {
        guard let config = ZeroSettleIAP.shared.currentConfig,
              let baseURL = ZeroSettleIAP.shared.effectiveBaseURL else {
            throw ZeroSettleIAPError.notConfigured
        }
        return Backend(baseURL: baseURL, publishableKey: config.publishableKey)
    }
}

// MARK: - Checkout WebView (loads on-demand with accordion detection)
struct CheckoutWebView: UIViewRepresentable {
    let url: URL
    let backgroundColor: UIColor
    let onLoaded: () -> Void
    let onPaymentMethodChanged: (String) -> Void
    let onCheckoutSuccess: (URL) -> Void
    
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
        
        // Add script message handlers for payment method changes and debug logs
        configuration.userContentController.add(context.coordinator, name: "paymentMethodChanged")
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
        let onCheckoutSuccess: (URL) -> Void
        
        init(
            backgroundColor: UIColor,
            onLoaded: @escaping () -> Void,
            onPaymentMethodChanged: @escaping (String) -> Void,
            onCheckoutSuccess: @escaping (URL) -> Void
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
              try {
                var style = document.createElement('style');
                style.innerHTML = `
                  html, body, .payment-sheet, .checkout-container, .container, #root, #app, main {
                    background-color: rgb(\(r), \(g), \(b)) !important;
                    background: rgb(\(r), \(g), \(b)) !important;
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
                `;
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
                // Check which payment method accordion is expanded
                if (isButtonExpanded('card')) {
                  return 'card';
                }
                if (isButtonExpanded('apple_pay')) {
                  return 'apple_pay';
                }
                return 'collapsed';
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

              // Initial probing (Stripe often hydrates late)
              setTimeout(function() { report('t+300ms'); }, 300);
              setTimeout(function() { report('t+800ms'); }, 800);
              setTimeout(function() { report('t+1500ms'); }, 1500);
              setTimeout(function() { report('t+3000ms'); }, 3000);

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

            let urlString = url.absoluteString
            let host = (url.host ?? "").lowercased()
            let path = url.path.lowercased()
            let query = (url.query ?? "").lowercased()

            let isNewWindow = (navigationAction.targetFrame == nil)
            let isMainFrame = (navigationAction.targetFrame?.isMainFrame ?? false)

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
                    DispatchQueue.main.async {
                        self.onCheckoutSuccess(url)
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
