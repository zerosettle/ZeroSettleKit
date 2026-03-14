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

    public enum Category: String, CaseIterable, Sendable {
        case migration = "Migration"
        case checkout = "Checkout"
        case cancelFlow = "CancelFlow"
        case entitlements = "Entitlements"
        case deepLinks = "DeepLinks"
        case network = "Network"
        case general = "General"
    }

    private static let loggers: [Category: OSLog] = {
        var dict: [Category: OSLog] = [:]
        for category in Category.allCases {
            dict[category] = OSLog(subsystem: subsystem, category: category.rawValue)
        }
        return dict
    }()

    private static func logger(for category: Category) -> OSLog {
        // Safe: eagerly populated for all cases via CaseIterable
        loggers[category]!
    }

    public static func log(
        _ message: String,
        category: Category = .general,
        type: OSLogType = .default
    ) {
        os_log("%{public}@", log: logger(for: category), type: type, message)
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
