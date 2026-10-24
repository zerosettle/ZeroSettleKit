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
        // Apple's `os_log` redacts arguments interpolated as `%{private}@`
        // when reading device logs from a non-debugger context (Console.app
        // sysdiagnose, customer-shared logs, third-party log readers). This
        // is the privacy contract the OS enforces.
        //
        // In DEBUG builds we use `%{public}@` so developers see the full
        // message during integration / local development. In RELEASE builds
        // we use `%{private}@` so production sysdiagnoses don't leak Stripe
        // client_secrets, user IDs, transaction IDs, or any other dynamic
        // log argument the SDK or its consumers pass through.
        //
        // Sensitive data should never appear in the format string itself —
        // only in the substituted argument. Audit ZSLogger call sites with:
        //   grep -n 'ZSLogger\.\(info\|debug\|error\|fault\|log\)' \\
        //     Sources/ZeroSettleKit | grep -v '\\(.*\\)'
        // ...and ensure every dynamic value is interpolated, not concatenated
        // into the format string.
        #if DEBUG
        os_log("%{public}@", log: logger(for: category), type: type, message)
        #else
        os_log("%{private}@", log: logger(for: category), type: type, message)
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
