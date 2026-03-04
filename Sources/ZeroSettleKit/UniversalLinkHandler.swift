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
internal struct ZeroSettleHandlerModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else {
                    ZSLogger.debug("onContinueUserActivity fired but webpageURL is nil", category: .deepLinks)
                    return
                }
                ZSLogger.info("onContinueUserActivity fired with URL: \(url.absoluteString)", category: .deepLinks)
                ZeroSettle.shared.handleUniversalLink(url)
            }
            .onOpenURL { url in
                ZSLogger.info("onOpenURL fired with URL: \(url.absoluteString)", category: .deepLinks)
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
