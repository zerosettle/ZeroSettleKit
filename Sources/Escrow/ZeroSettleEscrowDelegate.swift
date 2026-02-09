//
//  ZeroSettleEscrowDelegate.swift
//  ZeroSettleEscrow
//
//  Delegate protocol for escrow event callbacks.
//

import Foundation
import ZeroSettleCore

// MARK: - Session Creation Request

/// Parameters used when creating a game session.
/// Provided in failure callbacks to identify which creation attempt failed.
public struct SessionCreationRequest: Sendable {
    public let gameDefinitionId: UUID
    public let mode: GameMode
    public let entryFeeCents: Int
    public let maxPayoutMultiplier: Double

    public init(
        gameDefinitionId: UUID,
        mode: GameMode,
        entryFeeCents: Int,
        maxPayoutMultiplier: Double
    ) {
        self.gameDefinitionId = gameDefinitionId
        self.mode = mode
        self.entryFeeCents = entryFeeCents
        self.maxPayoutMultiplier = maxPayoutMultiplier
    }
}

// MARK: - Escrow Delegate

/// Delegate protocol to receive callbacks for ZeroSettle escrow events.
@MainActor
public protocol ZeroSettleEscrowDelegate: AnyObject {

    // MARK: - Authentication Events

    /// Called when user successfully authenticates.
    /// - Parameters:
    ///   - userId: The ZeroSettle user UUID
    ///   - walletAddress: The user's Solana wallet address
    func zeroSettleEscrowDidAuthenticate(userId: UUID, walletAddress: SolanaAddress)

    /// Called when user logs out.
    func zeroSettleEscrowDidLogout()

    /// Called when authentication fails.
    /// - Parameters:
    ///   - operation: The operation that failed (e.g., "sendOTP", "verifyOTP")
    ///   - error: The underlying error. Concrete type is
    ///     ``ZeroSettleEscrowError/authenticationFailed(operation:underlyingError:)``.
    func zeroSettleEscrowAuthenticationFailed(operation: String, error: Error)

    // MARK: - Balance Events

    /// Called when the user's balance is updated.
    /// - Parameter balanceCents: The new balance in cents
    func zeroSettleEscrowDidUpdateBalance(_ balanceCents: Int)

    /// Called when balance fetch fails.
    /// - Parameter error: The underlying error
    func zeroSettleEscrowBalanceFetchFailed(error: Error)

    // MARK: - Session Events

    /// Called when a game session is created.
    /// - Parameter session: The new game session
    func zeroSettleEscrowDidCreateSession(_ session: GameSession)

    /// Called when a game session state changes.
    /// - Parameters:
    ///   - session: The updated game session
    ///   - previousState: The previous session state
    func zeroSettleEscrowSessionStateChanged(_ session: GameSession, from previousState: SessionState)

    /// Called when escrow is confirmed and game can begin.
    /// - Parameter session: The session that is now ready
    func zeroSettleEscrowDidConfirm(session: GameSession)

    /// Called when a session is settled.
    /// - Parameter result: The settlement result
    func zeroSettleEscrowDidSettleSession(_ result: SettlementResult)

    // MARK: - Session Error Events

    /// Called when session creation fails.
    /// - Parameters:
    ///   - request: The creation parameters that were used
    ///   - error: The underlying error
    ///   - canRetry: Whether the operation can be retried
    func zeroSettleEscrowSessionCreationFailed(request: SessionCreationRequest, error: Error, canRetry: Bool)

    /// Called when escrow confirmation fails.
    /// - Parameters:
    ///   - sessionId: The session that failed to confirm
    ///   - error: The underlying error
    ///   - canRetry: Whether the operation can be retried
    func zeroSettleEscrowConfirmationFailed(sessionId: UUID, error: Error, canRetry: Bool)

    /// Called when settlement fails.
    /// - Parameters:
    ///   - sessionId: The session that failed to settle
    ///   - error: The underlying error. Concrete type is typically
    ///     ``ZeroSettleEscrowError/backendError(_:)`` or ``ZeroSettleEscrowError/transactionFailed(operation:message:)``.
    ///   - canRetry: Whether the operation can be retried
    func zeroSettleEscrowSettlementFailed(sessionId: UUID, error: Error, canRetry: Bool)
}

// MARK: - Default Implementations

public extension ZeroSettleEscrowDelegate {
    func zeroSettleEscrowDidAuthenticate(userId: UUID, walletAddress: SolanaAddress) {}
    func zeroSettleEscrowDidLogout() {}
    func zeroSettleEscrowAuthenticationFailed(operation: String, error: Error) {}
    func zeroSettleEscrowDidUpdateBalance(_ balanceCents: Int) {}
    func zeroSettleEscrowBalanceFetchFailed(error: Error) {}
    func zeroSettleEscrowDidCreateSession(_ session: GameSession) {}
    func zeroSettleEscrowSessionStateChanged(_ session: GameSession, from previousState: SessionState) {}
    func zeroSettleEscrowDidConfirm(session: GameSession) {}
    func zeroSettleEscrowDidSettleSession(_ result: SettlementResult) {}
    func zeroSettleEscrowSessionCreationFailed(request: SessionCreationRequest, error: Error, canRetry: Bool) {}
    func zeroSettleEscrowConfirmationFailed(sessionId: UUID, error: Error, canRetry: Bool) {}
    func zeroSettleEscrowSettlementFailed(sessionId: UUID, error: Error, canRetry: Bool) {}
}
