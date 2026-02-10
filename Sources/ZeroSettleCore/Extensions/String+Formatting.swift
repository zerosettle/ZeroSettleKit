//
//  String+Formatting.swift
//  ZeroSettleCore
//
//  String extensions for address formatting and validation.
//

import Foundation

public extension String {
    /// Format a wallet address as abbreviated (e.g., "ABC1...xyz9")
    func formatAsAddress(prefixLength: Int = 4, suffixLength: Int = 4) -> String {
        guard count > prefixLength + suffixLength + 3 else { return self }
        let prefix = String(self.prefix(prefixLength))
        let suffix = String(self.suffix(suffixLength))
        return "\(prefix)...\(suffix)"
    }

    /// Check if string is a valid Solana address (Base58, decodes to 32 bytes)
    var isValidSolanaAddress: Bool {
        guard count >= 32 && count <= 44 else { return false }
        guard let decoded = Base58.decode(self) else { return false }
        return decoded.count == 32
    }
}
