//
//  SafariPresentation.swift
//  ZeroSettleKit
//
//  Shared helpers for presenting `SFSafariViewController` consistently
//  across the legacy migration flow (`WebCheckoutFlow.openInSafariVC`)
//  and the unified offer flow (`OfferTipView.startBrowserCheckout`).
//

#if os(iOS)
import UIKit
import SafariServices

internal enum SafariPresentation {
    /// Returns the topmost presented view controller in the foreground-active
    /// key window — the correct anchor for presenting a sheet without stacking
    /// it underneath another modal. `nil` when no foreground-active scene exists
    /// (e.g. during scene transitions or backgrounded states).
    @MainActor
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

extension SFSafariViewController {
    /// Configures the receiver as a slide-up page sheet with ZeroSettle's
    /// standard in-app browser-checkout sizing. Default UIKit presentation
    /// on iPhone is full-screen.
    @MainActor
    func applyZSPageSheetPresentation() {
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }
}
#endif
