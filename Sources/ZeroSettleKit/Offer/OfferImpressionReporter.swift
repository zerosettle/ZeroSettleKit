import Foundation
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Shared core for on-screen offer impressions: resolve the offer (explicit
/// args, else ZeroSettle.currentOffer), dedupe once per (user, session,
/// variant), and fire-and-forget report. Used by the SwiftUI modifier and the
/// UIKit interaction.
@MainActor
final class OfferImpressionReporter {
    private let dedupe = ImpressionDedupe()

    func resolve(productId: String?, variantId: Int?, flowType: String?) -> ResolvedOffer? {
        if let productId {
            return ResolvedOffer(productId: productId, variantId: variantId, flowType: flowType ?? "migration")
        }
        return ZeroSettle.shared.currentOffer
    }

    #if DEBUG
    func shouldReportForTesting(_ offer: ResolvedOffer) -> Bool { _shouldReport(offer) }
    #endif

    private func _shouldReport(_ offer: ResolvedOffer) -> Bool {
        let key = "\(Self.activeUserId()):\(ZeroSettle.shared.sessionId):\(offer.variantId ?? -1)"
        return dedupe.shouldReport(key)
    }

    /// Called when the view is >=50% on screen. Resolves + dedups + reports.
    func reportIfVisible(productId: String?, variantId: Int?, flowType: String?) {
        guard let offer = resolve(productId: productId, variantId: variantId, flowType: flowType) else { return }
        guard _shouldReport(offer) else { return }
        let uid = Self.activeUserId()
        let session = ZeroSettle.shared.sessionId
        Task {
            do {
                let backend = try ZeroSettle.shared.makeBackend()
                try await backend.reportOfferViewed(
                    userId: uid, productId: offer.productId,
                    sessionId: session, variantId: offer.variantId, flowType: offer.flowType
                )
            } catch {
                ZSLogger.debug("[OfferImpression] report failed: \(error)", category: .migration)
            }
        }
    }

    private static func activeUserId() -> String {
        ZeroSettle.shared.currentUserId ?? "anonymous"
    }
}
