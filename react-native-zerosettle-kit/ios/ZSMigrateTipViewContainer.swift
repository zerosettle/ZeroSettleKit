import UIKit
import SwiftUI
import ZeroSettleKit

@objc(ZSMigrateTipViewContainer)
public final class ZSMigrateTipViewContainer: UIView {
    private var hostingController: UIHostingController<AnyView>?
    
    // Props exposed to React Native
    @objc var backgroundColorHex: NSString = "#000000" {
        didSet { rebuild() }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        rebuild()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rebuild()
    }
    
    private func rebuild() {
        // Convert hex to SwiftUI Color
        let uiColor = UIColor(hex: backgroundColorHex as String) ?? .black
        let swiftUIColor = Color(uiColor)
        
        let root = ZSMigrateTipView(backgroundColor: swiftUIColor)
        let any = AnyView(root)
        
        if let hc = hostingController {
            hc.rootView = any
            hc.view.invalidateIntrinsicContentSize()
            setNeedsLayout()
            return
        }
        
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
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        hostingController?.view.frame = bounds
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
