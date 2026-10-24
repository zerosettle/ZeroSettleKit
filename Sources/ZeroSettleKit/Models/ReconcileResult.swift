import Foundation

/// The outcome of ``ZeroSettle/reconcile(linkToken:)``.
public struct ReconcileResult: Sendable, Equatable {
    /// Identifier of the reconciliation record.
    public let reconciliationId: Int
    /// The id whose purchases were moved (typically the guest id).
    public let fromUserId: String
    /// The id that received them (typically the account id).
    public let intoUserId: String
    /// How many transactions moved.
    public let movedTransactions: Int
    /// How many entitlements moved.
    public let movedEntitlements: Int

    public init(
        reconciliationId: Int,
        fromUserId: String,
        intoUserId: String,
        movedTransactions: Int,
        movedEntitlements: Int
    ) {
        self.reconciliationId = reconciliationId
        self.fromUserId = fromUserId
        self.intoUserId = intoUserId
        self.movedTransactions = movedTransactions
        self.movedEntitlements = movedEntitlements
    }
}
