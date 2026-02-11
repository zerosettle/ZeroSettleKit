//
//  CustomerPortalFlow.swift
//  ZeroSettleKit
//
//  Presents the Stripe customer portal in an SFSafariViewController.
//

import Foundation
import SafariServices
import UIKit

#if canImport(ZeroSettleCore)
@_implementationOnly import ZeroSettleCore
#endif

// MARK: - Customer Portal Flow

/// Presents the Stripe customer portal in an SFSafariViewController.
/// Simpler than WebCheckoutFlow — no callback URL parsing, just present and await dismiss.
internal final class CustomerPortalFlow: NSObject {

    /// Continuation for awaiting portal dismissal.
    private var continuation: CheckedContinuation<Void, Never>?

    /// Reference to the presented Safari view controller.
    private weak var presentedSafariVC: SFSafariViewController?

    // MARK: - Present Portal

    /// Present the customer portal URL in an SFSafariViewController.
    /// Returns when the user dismisses the Safari view controller.
    @MainActor
    func presentPortal(url: URL) async {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            ZSLogger.error("Unable to find root view controller for customer portal", category: .iap)
            return
        }

        // Find the topmost presented view controller
        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }

        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        safari.preferredControlTintColor = .systemGreen
        safari.dismissButtonStyle = .close

        if #available(iOS 15.0, *) {
            safari.modalPresentationStyle = .pageSheet
            if let sheet = safari.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
        } else {
            safari.modalPresentationStyle = .formSheet
        }

        self.presentedSafariVC = safari

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            topController.present(safari, animated: true)
        }
    }
}

// MARK: - SFSafariViewControllerDelegate

extension CustomerPortalFlow: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        ZSLogger.debug("Customer portal dismissed by user", category: .iap)
        presentedSafariVC = nil
        continuation?.resume()
        continuation = nil
    }
}
