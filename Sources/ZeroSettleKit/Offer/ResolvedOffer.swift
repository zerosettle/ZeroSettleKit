/// The currently-resolved eligible offer, used to auto-fill impression
/// reporting when the caller doesn't pass explicit identifiers.
public struct ResolvedOffer: Sendable, Equatable {
    public let productId: String
    public let variantId: Int?
    public let flowType: String

    public init(productId: String, variantId: Int?, flowType: String) {
        self.productId = productId
        self.variantId = variantId
        self.flowType = flowType
    }
}
