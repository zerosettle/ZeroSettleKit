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
        case migration = "Migration"
        case checkout = "Checkout"
        case cancelFlow = "CancelFlow"
        case entitlements = "Entitlements"
        case deepLinks = "DeepLinks"
        case network = "Network"
        case general = "General"
    }

    nonisolated(unsafe) private static var loggers: [Category: OSLog] = [:]

    private static func logger(for category: Category) -> OSLog {
        if let cached = loggers[category] { return cached }
        let log = OSLog(subsystem: subsystem, category: category.rawValue)
        loggers[category] = log
        return log
    }

    public static func log(
        _ message: String,
        category: Category = .general,
        type: OSLogType = .default
    ) {
        os_log("%{public}@", log: logger(for: category), type: type, message)
        #if DEBUG
        print("[ZeroSettle/\(category.rawValue)] \(message)")
        #endif
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
