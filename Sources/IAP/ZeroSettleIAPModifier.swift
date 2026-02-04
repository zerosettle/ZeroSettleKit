//
//  ZeroSettleIAPModifier.swift
//  ZeroSettleIAP
//
//  SwiftUI view modifier for automatic universal link handling.
//

import SwiftUI

#if canImport(ZeroSettleCore)
import ZeroSettleCore
#endif

// MARK: - View Modifier

/// A view modifier that automatically handles ZeroSettle IAP universal link callbacks.
/// Apply this to your root view to enable automatic checkout callback handling.
public struct ZeroSettleIAPHandlerModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                ZeroSettleIAP.shared.handleUniversalLink(url)
            }
            .onOpenURL { url in
                ZeroSettleIAP.shared.handleUniversalLink(url)
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
    ///                 .zeroSettleIAPHandler()
    ///         }
    ///     }
    /// }
    /// ```
    func zeroSettleIAPHandler() -> some View {
        modifier(ZeroSettleIAPHandlerModifier())
    }
}
