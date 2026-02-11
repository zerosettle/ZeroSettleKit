//
//  Logger.swift
//  ZeroSettleCore
//
//  Structured logging utility using os.log for clean, filterable logs.
//

import Foundation
import os.log

public enum ZSLogger {
    private static let subsystem = "com.zerosettle.kit"

    public enum Category: String {
        case auth = "Auth"
        case balance = "Balance"
        case signing = "Signing"
        case network = "Network"
        case wallet = "Wallet"
        case blockchain = "Blockchain"
        case escrow = "Escrow"
        case iap = "IAP"
        case general = "General"
    }

    public static func log(
        _ message: String,
        category: Category = .general,
        type: OSLogType = .default
    ) {
        let log = OSLog(subsystem: subsystem, category: category.rawValue)
        os_log("%{public}@", log: log, type: type, message)
    }

    public static func debug(_ message: String, category: Category = .general) {
        log(message, category: category, type: .debug)
    }

    public static func info(_ message: String, category: Category = .general) {
        log(message, category: category, type: .info)
    }

    public static func error(_ message: String, category: Category = .general) {
        log(message, category: category, type: .error)
    }

    public static func fault(_ message: String, category: Category = .general) {
        log(message, category: category, type: .fault)
    }
}
