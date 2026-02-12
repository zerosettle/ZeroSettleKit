import Foundation
import UIKit
import SwiftUI
import ZeroSettleKit

@objc(ZSMigrateTipModule)
class ZSMigrateTipModule: NSObject {
    
    @objc
    static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    @objc
    func presentMigrateTip(_ backgroundColorHex: String, userId: String) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                print("❌ [ZSMigrateTipModule] Could not find root view controller")
                return
            }

            // Find the topmost presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            // Convert hex to SwiftUI Color
            let uiColor = UIColor(hex: backgroundColorHex) ?? .black
            let swiftUIColor = Color(uiColor)

            // Create the SwiftUI view
            let migrateTipView = ZSMigrateTipView(backgroundColor: swiftUIColor, userId: userId)
            
            // Wrap in a hosting controller
            let hostingController = UIHostingController(rootView: 
                ZStack {
                    // Semi-transparent background
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            // Dismiss on background tap
                            topVC.presentedViewController?.dismiss(animated: true)
                        }
                    
                    // The migrate tip view
                    VStack {
                        Spacer()
                        migrateTipView
                            .padding(.horizontal, 16)
                            .padding(.bottom, 34)
                    }
                }
            )
            
            hostingController.view.backgroundColor = .clear
            hostingController.modalPresentationStyle = .overFullScreen
            hostingController.modalTransitionStyle = .crossDissolve
            
            topVC.present(hostingController, animated: true)
            print("✅ [ZSMigrateTipModule] Presented ZSMigrateTipView modally")
        }
    }
    
    @objc
    func dismissMigrateTip() {
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

// MARK: - UIColor hex helper (if not already defined)
fileprivate extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
