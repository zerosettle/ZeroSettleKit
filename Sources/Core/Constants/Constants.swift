//
//  Constants.swift
//  ZeroSettleCore
//
//  Centralized constants for magic numbers and commonly used values.
//

import Foundation

public enum ZeroSettleConstants {

    // MARK: - USDC Token

    public enum USDC {
        /// USDC has 6 decimal places
        public static let decimals = 6

        /// Conversion factor from USDC smallest units to cents
        /// 1 USDC = 1,000,000 units, 1 cent = 10,000 units
        public static let unitsPerCent: UInt64 = 10_000

        /// Convert smallest units to cents
        public static func toCents(_ units: UInt64) -> Int {
            Int(units / unitsPerCent)
        }

        /// Convert cents to smallest units
        public static func toUnits(_ cents: Int) -> UInt64 {
            UInt64(cents) * unitsPerCent
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
