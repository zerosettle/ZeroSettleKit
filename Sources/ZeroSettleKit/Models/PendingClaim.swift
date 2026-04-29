import Foundation

/// A StoreKit purchase that the current user could claim from a different
/// ZeroSettle account.
///
/// Surfaced when `sync_storekit_transaction` returns `conflict: true,
/// claim_available: true`. The consuming app can render UX
/// ("This purchase belongs to another account — transfer it?") and call
/// `ZeroSettle.shared.transferStoreKitOwnershipToCurrentUser(productId:)`
/// to actually claim — or ignore.
public struct PendingClaim: Equatable, Sendable {
    public let productId: String
    public let originalTransactionId: String
    /// Truncated SHA256 hash of the existing owner's external_user_id.
    /// Non-reversible; safe to display or log. Use for de-duplication or
    /// "previous account on this device" hints.
    public let existingOwnerHint: String

    public init(productId: String, originalTransactionId: String, existingOwnerHint: String) {
        self.productId = productId
        self.originalTransactionId = originalTransactionId
        self.existingOwnerHint = existingOwnerHint
    }
}
