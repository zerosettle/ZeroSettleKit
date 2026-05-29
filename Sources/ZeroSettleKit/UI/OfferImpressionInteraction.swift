import UIKit

/// Attach to any UIView to report an on-screen offer impression when the view
/// is at least 50% visible, once per session. Auto-resolves the active offer
/// (pass identifiers to override).
///
///     let banner = MyDirectBillingBanner()        // any UIView
///     banner.addInteraction(OfferImpressionInteraction())
@MainActor
public final class OfferImpressionInteraction: NSObject, UIInteraction {
    public private(set) weak var view: UIView?

    private let productId: String?
    private let variantId: Int?
    private let flowType: String?
    private let reporter = OfferImpressionReporter()
    private var displayLink: CADisplayLink?

    public init(productId: String? = nil, variantId: Int? = nil, flowType: String? = nil) {
        self.productId = productId
        self.variantId = variantId
        self.flowType = flowType
        super.init()
    }

    public func willMove(to view: UIView?) {
        if view == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    public func didMove(to view: UIView?) {
        self.view = view
        guard view != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard let view, let window = view.window else { return }
        let frameInWindow = view.convert(view.bounds, to: nil)
        let fraction = BannerVisibility.visibleFraction(of: frameInWindow, in: window.bounds)
        guard fraction >= 0.5 else { return }
        // Threshold met — stop polling and report (reporter also dedups).
        displayLink?.invalidate()
        displayLink = nil
        reporter.reportIfVisible(productId: productId, variantId: variantId, flowType: flowType)
    }
}
