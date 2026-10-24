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
    /// True only when the SDK adopted ``intoUserId`` as the current user.
    /// When false and you want to continue as the account, call
    /// `identify(.user(id: result.intoUserId))` (the move itself has happened).
    public let switchedToAccount: Bool

    public init(
        reconciliationId: Int,
        fromUserId: String,
        intoUserId: String,
        movedTransactions: Int,
        movedEntitlements: Int,
        switchedToAccount: Bool = false
    ) {
        self.reconciliationId = reconciliationId
        self.fromUserId = fromUserId
        self.intoUserId = intoUserId
        self.movedTransactions = movedTransactions
        self.movedEntitlements = movedEntitlements
        self.switchedToAccount = switchedToAccount
    }
}
