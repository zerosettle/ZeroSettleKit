import SwiftUI

private struct OfferImpressionModifier: ViewModifier {
    let productId: String?
    let variantId: Int?
    let flowType: String?
    @State private var reporter = OfferImpressionReporter()

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { fire(geo.frame(in: .global)) }
                    .onChange(of: geo.frame(in: .global)) { _, f in fire(f) }
            }
        )
    }

    @MainActor
    private func fire(_ frame: CGRect) {
        if BannerVisibility.isOnScreen(frame, in: UIScreen.main.bounds, threshold: 0.5) {
            reporter.reportIfVisible(productId: productId, variantId: variantId, flowType: flowType)
        }
    }
}

public extension View {
    /// Report an on-screen impression of an offer banner when this view is
    /// >=50% visible, once per session. Auto-resolves the active offer; pass
    /// identifiers only to override.
    func offerImpression(productId: String? = nil, variantId: Int? = nil, flowType: String? = nil) -> some View {
        modifier(OfferImpressionModifier(productId: productId, variantId: variantId, flowType: flowType))
    }
}
