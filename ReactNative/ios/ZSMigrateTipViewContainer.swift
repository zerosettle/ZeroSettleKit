import UIKit
import SwiftUI
import ZeroSettleKit

#if canImport(React)
import React
#endif

/// A UIKit container that hosts the ZSMigrateTipView SwiftUI view.
/// This view manages all its own internal state (expand/collapse, checkout, dismissal, etc.)
/// and only accepts a backgroundColor from React Native.
@objc(ZSMigrateTipViewContainer)
public final class ZSMigrateTipViewContainer: UIView {
    
    // MARK: - React Native Props
    
    /// Background color as hex string "#RRGGBB" from React Native
    @objc var backgroundColorHex: NSString? = nil {
        didSet { renderIfNeeded() }
    }
    
    // MARK: - Private Properties
    
    private var hostingController: UIHostingController<AnyView>?
    
    // MARK: - Initialization
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        renderIfNeeded()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Rendering
    
    private func renderIfNeeded() {
        let uiColor = UIColor(hex: backgroundColorHex as String?) ?? .black
        let swiftUIColor = Color(uiColor)
        
        // Create the SwiftUI view with just backgroundColor
        // All internal state (isExpanded, isDismissed, checkout, etc.) is managed by the view itself
        let swiftUIView = ZSMigrateTipView(backgroundColor: swiftUIColor)
        let wrappedView = AnyView(swiftUIView)
        
        if let existingHost = hostingController {
            existingHost.rootView = wrappedView
        } else {
            let host = UIHostingController(rootView: wrappedView)
            host.view.backgroundColor = .clear
            hostingController = host
            addSubview(host.view)
        }
        
        setNeedsLayout()
    }
    
    // MARK: - Layout
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        hostingController?.view.frame = bounds
    }
    
    /// Returns the intrinsic content size for React Native layout
    public override var intrinsicContentSize: CGSize {
        return hostingController?.view.intrinsicContentSize ?? CGSize(width: UIView.noIntrinsicMetric, height: 220)
    }
}

// MARK: - UIColor Hex Extension

private extension UIColor {
    /// Creates a UIColor from a hex string (e.g., "#FF5733" or "FF5733")
    convenience init?(hex: String?) {
        guard var hexString = hex else { return nil }
        
        hexString = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }
        
        guard hexString.count == 6,
              let intValue = Int(hexString, radix: 16) else {
            return nil
        }
        
        let red = CGFloat((intValue >> 16) & 0xFF) / 255.0
        let green = CGFloat((intValue >> 8) & 0xFF) / 255.0
        let blue = CGFloat(intValue & 0xFF) / 255.0
        
        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
