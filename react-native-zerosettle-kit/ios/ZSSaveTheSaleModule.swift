import Foundation
import UIKit
import SwiftUI
import ZeroSettleKit

@objc(ZSSaveTheSaleModule)
class ZSSaveTheSaleModule: NSObject {

    @objc
    static func requiresMainQueueSetup() -> Bool {
        return true
    }

    @objc
    func presentSaveTheSaleSheet(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                reject("no_view_controller", "Could not find root view controller", nil)
                return
            }

            // Find the topmost presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            ZSSaveTheSaleSheet.present(from: topVC) { result in
                switch result {
                case .pauseAccount:
                    resolve("pauseAccount")
                case .stayWithDiscount:
                    resolve("stayWithDiscount")
                case .dismissed:
                    resolve("dismissed")
                }
            }
        }
    }

    @objc
    func dismissSaveTheSaleSheet() {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                return
            }

            // Find and dismiss the presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            if topVC != rootVC {
                topVC.dismiss(animated: true)
            }
        }
    }
}
