//
//  UniversalLinkHandler.swift
//  ZeroSettleKit
//
//  SwiftUI view modifier for automatic universal link handling.
//

import SwiftUI

#if canImport(ZeroSettleCore)
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif
#endif

// MARK: - View Modifier

/// A view modifier that handles ZeroSettle checkout callbacks via universal links
/// and hosts the shared WebView preloader pool in the view hierarchy.
///
/// ZeroSettle uses **universal links only** — no custom URL schemes.
/// The developer must add the Associated Domains entitlement for this to work:
///   `applinks:api.zerosettle.io?mode=developer` (dev)
///   `applinks:api.zerosettle.io` (production)
///
/// Apply this to your root view to enable automatic checkout callback handling.
internal struct ZeroSettleHandlerModifier: ViewModifier {
    @ObservedObject private var pool = CheckoutPreloaderPool.shared

    public func body(content: Content) -> some View {
        content
            // Host the shared WebView pool so pre-rendered WKWebViews
            // are in the view hierarchy and can load/render content.
            .background(
                PoolPreloaderHost(webViews: pool.webViews)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            )
            // Primary path: universal links fire via NSUserActivity.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else {
                    ZSLogger.debug("onContinueUserActivity fired but webpageURL is nil", category: .deepLinks)
                    return
                }
                ZSLogger.info("onContinueUserActivity fired with URL: \(url.redactedForLogs)", category: .deepLinks)
                ZeroSettle.shared.handleUniversalLink(url)
            }
            // Safety net: onOpenURL can also deliver universal links in some
            // SwiftUI lifecycle edge cases.  We do NOT register a custom URL
            // scheme — this handler only processes https:// universal links.
            .onOpenURL { url in
                ZSLogger.info("onOpenURL fired with URL: \(url.redactedForLogs)", category: .deepLinks)
                ZeroSettle.shared.handleUniversalLink(url)
            }
            .onAppear {
                ZSLogger.debug("handler installed on view appear", category: .deepLinks)
                ZeroSettle.shared.handlerInstalled = true
            }
    }
}

// MARK: - View Extension

public extension View {
    /// Enables automatic handling of ZeroSettle IAP universal link callbacks.
    ///
    /// Apply this modifier to your app's root view:
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///     var body: some Scene {
    ///         WindowGroup {
    ///             ContentView()
    ///                 .zeroSettleHandler()
    ///         }
    ///     }
    /// }
    /// ```
    func zeroSettleHandler() -> some View {
        modifier(ZeroSettleHandlerModifier())
    }
}
