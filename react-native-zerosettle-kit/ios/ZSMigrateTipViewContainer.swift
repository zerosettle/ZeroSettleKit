import UIKit
import SwiftUI
import ZeroSettleKit

@objc(ZSMigrateTipViewContainer)
public final class ZSMigrateTipViewContainer: UIView {
    private var hostingController: UIHostingController<AnyView>?
    
    // Props exposed to React Native
    @objc var backgroundColorHex: NSString = "#000000" {
        didSet { updateSwiftUIView() }
    }
    @objc var userId: NSString = "" {
        didSet { updateSwiftUIView() }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        buildView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }
    
    private func buildView() {
        // Convert hex to SwiftUI Color
        let uiColor = UIColor(hex: backgroundColorHex as String) ?? .black
        let swiftUIColor = Color(uiColor)

        let root = ZSMigrateTipView(userId: userId as String, backgroundColor: swiftUIColor)
        let any = AnyView(root)

        let hc = UIHostingController(rootView: any)
        hostingController = hc

        hc.view.backgroundColor = .clear
        hc.view.translatesAutoresizingMaskIntoConstraints = false

        addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        attachHostingControllerIfPossible()
    }
    
    private func updateSwiftUIView() {
        guard let hc = hostingController else { return }

        let uiColor = UIColor(hex: backgroundColorHex as String) ?? .black
        let swiftUIColor = Color(uiColor)

        let root = ZSMigrateTipView(userId: userId as String, backgroundColor: swiftUIColor)
        hc.rootView = AnyView(root)
        hc.view.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        hostingController?.view.frame = bounds
    }
    
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        
        if window != nil {
            attachHostingControllerIfPossible()
        } else {
            // Clean up when removed from window
            if let hc = hostingController {
                hc.willMove(toParent: nil)
                hc.view.removeFromSuperview()
                hc.removeFromParent()
                hostingController = nil
            }
        }
    }

    private func attachHostingControllerIfPossible() {
        guard let hc = hostingController else { return }

        let parentVC: UIViewController? = {
            if let windowScene = window?.windowScene,
               let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
               let root = keyWindow.rootViewController {
                return root
            }
            return findParentViewController()
        }()

        guard let resolvedParent = parentVC else { return }

        if hc.parent !== resolvedParent {
            hc.willMove(toParent: nil)
            hc.removeFromParent()
            resolvedParent.addChild(hc)
            hc.didMove(toParent: resolvedParent)
        }
    }
    
    /// Traverse the responder chain to find the nearest UIViewController
    private func findParentViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
}

// MARK: - UIColor hex helper
private extension UIColor {
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
