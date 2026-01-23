//
//  PDADerivation.swift
//  ZeroSettleBlockchain
//
//  Program Derived Address (PDA) utilities for Solana.
//
//  NOTE: Most PDA derivation is handled server-side. The server builds
//  transactions and the client only signs them. Only ATA derivation is
//  commonly needed client-side for balance checks.
//
//  TODO: Review after implementation - game session/escrow PDAs may be removable.
//

import Foundation
import Solana
import ZeroSettleCore

// MARK: - PDA Errors

public enum PDAError: Error, LocalizedError {
    case invalidPublicKey(String)
    case derivationFailed(String)
    case invalidSeed

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey(let address):
            return "Invalid public key: \(address)"
        case .derivationFailed(let reason):
            return "PDA derivation failed: \(reason)"
        case .invalidSeed:
            return "Invalid seed data"
        }
    }
}

// MARK: - PDA Derivation

public enum PDADerivation {

    /// Derive Associated Token Account (ATA) address.
    /// This is the primary client-side PDA derivation needed for balance checks.
    public static func deriveATA(wallet: String, mint: String) throws -> String {
        guard let walletKey = PublicKey(string: wallet) else {
            throw PDAError.invalidPublicKey(wallet)
        }

        guard let mintKey = PublicKey(string: mint) else {
            throw PDAError.invalidPublicKey(mint)
        }

        let result = PublicKey.associatedTokenAddress(
            walletAddress: walletKey,
            tokenMintAddress: mintKey
        )

        switch result {
        case .success(let ata):
            return ata.base58EncodedString
        case .failure(let error):
            throw PDAError.derivationFailed(error.localizedDescription)
        }
    }

    // MARK: - Server-Side PDAs (May be removable)
    //
    // The following PDAs are typically derived server-side when building
    // transactions. Keeping them here for reference but they may not be
    // needed in the final implementation.

    /// Derive Game Session PDA - Seeds: ["game_session", player, session_id]
    /// NOTE: Server typically handles this.
    public static func deriveGameSessionPDA(
        programId: String,
        player: String,
        sessionId: [UInt8]
    ) throws -> String {
        guard let programKey = PublicKey(string: programId) else {
            throw PDAError.invalidPublicKey(programId)
        }

        guard let playerKey = PublicKey(string: player) else {
            throw PDAError.invalidPublicKey(player)
        }

        let seeds: [Data] = [
            Data("game_session".utf8),
            Data(playerKey.bytes),
            Data(sessionId)
        ]

        let result = PublicKey.findProgramAddress(seeds: seeds, programId: programKey)

        switch result {
        case .success(let pda):
            return pda.0.base58EncodedString
        case .failure(let error):
            throw PDAError.derivationFailed(error.localizedDescription)
        }
    }

    /// Derive Escrow PDA - Seeds: ["escrow", game_session]
    /// NOTE: Server typically handles this.
    public static func deriveEscrowPDA(programId: String, gameSession: String) throws -> String {
        guard let programKey = PublicKey(string: programId) else {
            throw PDAError.invalidPublicKey(programId)
        }

        guard let sessionKey = PublicKey(string: gameSession) else {
            throw PDAError.invalidPublicKey(gameSession)
        }

        let seeds: [Data] = [
            Data("escrow".utf8),
            Data(sessionKey.bytes)
        ]

        let result = PublicKey.findProgramAddress(seeds: seeds, programId: programKey)

        switch result {
        case .success(let pda):
            return pda.0.base58EncodedString
        case .failure(let error):
            throw PDAError.derivationFailed(error.localizedDescription)
        }
    }

    /// Convert UUID string to 16-byte session ID
    public static func sessionIdFromUUID(_ uuidString: String) throws -> [UInt8] {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw PDAError.invalidSeed
        }

        return withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }
}
