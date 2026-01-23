import Foundation

/// Delegate protocol for ZeroSettle events
public protocol ZeroSettleDelegate: AnyObject {
    // MARK: - Authentication Events

    /// Called when user successfully authenticates
    /// - Parameters:
    ///   - userId: The authenticated user's ID
    ///   - wallet: Information about the created/connected wallet
    func didAuthenticate(userId: String, wallet: WalletInfo)

    /// Called when user logs out
    func didLogout()

    // MARK: - Funding Events

    /// Called when user initiates a funding transaction
    /// - Parameters:
    ///   - amount: The amount being added
    ///   - currency: The currency (e.g., "USD")
    func didInitiateFunding(amount: Decimal, currency: String)

    /// Called when funding completes successfully
    /// - Parameters:
    ///   - amount: The amount that was added
    ///   - currency: The currency
    ///   - transactionHash: Optional blockchain transaction hash
    func didCompleteFunding(amount: Decimal, currency: String, transactionHash: String?)

    /// Called when funding fails
    /// - Parameter error: The error that occurred
    func didFailFunding(error: Error)
    
    // MARK: - Transaction Events

    /// Called before sending a transaction
    /// - Parameter transaction: The transaction about to be sent
    func willSendTransaction(transaction: PreparedTransaction)

    /// Called when transaction is successfully sent
    /// - Parameter txHash: The transaction hash
    func didSendTransaction(txHash: String)

    /// Called when transaction is confirmed on-chain
    /// - Parameters:
    ///   - txHash: The transaction hash
    ///   - receipt: The transaction receipt
    func didConfirmTransaction(txHash: String, receipt: TransactionReceipt)

    /// Called when transaction fails
    /// - Parameter error: The error that occurred
    func didFailTransaction(error: Error)
}

// MARK: - Default Implementations (Optional)

public extension ZeroSettleDelegate {
    func didAuthenticate(userId: String, wallet: WalletInfo) {}
    func didLogout() {}
    func didInitiateFunding(amount: Decimal, currency: String) {}
    func didCompleteFunding(amount: Decimal, currency: String, transactionHash: String?) {}
    func didFailFunding(error: Error) {}
    func willSendTransaction(transaction: PreparedTransaction) {}
    func didSendTransaction(txHash: String) {}
    func didConfirmTransaction(txHash: String, receipt: TransactionReceipt) {}
    func didFailTransaction(error: Error) {}
}
