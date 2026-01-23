//
//  Constants.swift
//  ZeroSettleKit
//
//  Centralized constants for magic numbers and commonly used values.
//

import Foundation

public enum ZeroSettleConstants {

    // MARK: - USDC Token

    public enum USDC {
        /// USDC has 6 decimal places
        public static let decimals = 6

        /// Conversion factor from USDC smallest units (lamports) to cents
        /// 1 USDC = 1,000,000 lamports, 1 cent = 10,000 lamports
        public static let lamportsPerCent: UInt64 = 10_000

        /// Convert lamports to cents
        public static func toCents(_ lamports: UInt64) -> Int {
            Int(lamports / lamportsPerCent)
        }

        /// Convert cents to lamports
        public static func toLamports(_ cents: Int) -> UInt64 {
            UInt64(cents) * lamportsPerCent
        }

        /// Format cents as a dollar string (e.g., "$1.50")
        public static func formatCents(_ cents: Int) -> String {
            String(format: "$%.2f", Double(cents) / 100.0)
        }

        /// Format cents as a compact string without $ (e.g., "1.50")
        public static func formatCentsCompact(_ cents: Int) -> String {
            String(format: "%.2f", Double(cents) / 100.0)
        }
    }

    // MARK: - Solana Programs

    public enum Solana {
        public static let tokenProgramId = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        public static let associatedTokenProgramId = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
        public static let systemProgramId = "11111111111111111111111111111111"
        public static let rentSysvar = "SysvarRent111111111111111111111111111111111"
    }

    // MARK: - Network

    public enum Network {
        public static let defaultTimeoutSeconds: TimeInterval = 30
        public static let websocketReconnectDelaySeconds: TimeInterval = 3
    }
}
