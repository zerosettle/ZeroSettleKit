//
//  UniversalLinkHandler.swift
//  ZeroSettleKit
//
//  SwiftUI view modifier for automatic universal link handling.
//

import SwiftUI

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - View Modifier

/// A view modifier that automatically handles ZeroSettle IAP universal link callbacks.
/// Apply this to your root view to enable automatic checkout callback handling.
public struct ZeroSettleHandlerModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else {
                    ZSLogger.debug("[UniversalLinkHandler] onContinueUserActivity fired but webpageURL is nil", category: .iap)
                    return
                }
                ZSLogger.info("[UniversalLinkHandler] onContinueUserActivity fired with URL: \(url.absoluteString)", category: .iap)
                ZeroSettle.shared.handleUniversalLink(url)
            }
            .onOpenURL { url in
                ZSLogger.info("[UniversalLinkHandler] onOpenURL fired with URL: \(url.absoluteString)", category: .iap)
                ZeroSettle.shared.handleUniversalLink(url)
            }
            .onAppear {
                ZSLogger.debug("[UniversalLinkHandler] handler installed on view appear", category: .iap)
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
