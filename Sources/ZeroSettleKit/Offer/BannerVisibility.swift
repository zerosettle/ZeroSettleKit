import CoreGraphics

/// Pure geometry for deciding whether the offer banner is "on screen".
/// Vertical-only: the banner spans the content width, so vertical scroll
/// position is what determines visibility.
enum BannerVisibility {
    /// Fraction (0...1) of the card's HEIGHT lying within the viewport vertically.
    static func visibleFraction(of card: CGRect, in viewport: CGRect) -> CGFloat {
        guard card.height > 0 else { return 0 }
        let top = max(card.minY, viewport.minY)
        let bottom = min(card.maxY, viewport.maxY)
        let visible = max(0, bottom - top)
        return min(1, visible / card.height)
    }

    /// Whether at least `threshold` of the card's height is on screen.
    static func isOnScreen(_ card: CGRect, in viewport: CGRect, threshold: CGFloat = 0.5) -> Bool {
        visibleFraction(of: card, in: viewport) >= threshold
    }
}
