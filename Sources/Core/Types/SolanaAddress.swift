//
//  SolanaAddress.swift
//  ZeroSettleCore
//
//  Type-safe wrapper for Solana public key addresses.
//

import Foundation

/// A validated Solana public key address.
/// Ensures addresses are properly formatted Base58 strings that decode to 32 bytes.
public struct SolanaAddress: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {

    /// The raw Base58-encoded address string
    public let base58: String

    /// Initialize with a Base58 address string.
    /// - Parameter base58: The Base58-encoded address
    /// - Throws: `SolanaAddressError.invalid` if the address is not valid
    public init(_ base58: String) throws {
        guard base58.isValidSolanaAddress else {
            throw SolanaAddressError.invalid(base58)
        }
        self.base58 = base58
    }

    /// Initialize without validation (use when you trust the source)
    /// - Parameter trustedBase58: A known-valid Base58 address
    public init(trusted trustedBase58: String) {
        self.base58 = trustedBase58
    }

    // MARK: - CustomStringConvertible

    public var description: String { base58 }

    /// Abbreviated format for display (e.g., "ABC1...xyz9")
    public var abbreviated: String {
        base58.formatAsAddress()
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base58)
    }
}

// MARK: - Errors

public enum SolanaAddressError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let address):
            return "Invalid Solana address: \(address)"
        }
    }
}
