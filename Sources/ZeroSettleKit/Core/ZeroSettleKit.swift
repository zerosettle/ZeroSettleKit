//
//  ZeroSettleKit.swift
//  ZeroSettleKit
//
//  Global configuration entrypoint for ZeroSettleKit.
//

import Foundation

/// Global entry point for configuring ZeroSettleKit from `@main` apps.
public enum ZeroSettleKit {
    // MARK: - Embedded Coinbase credentials (WordPlay production)
    // These are embedded so clients don't need to supply them or expose secrets.
    private static let embeddedCoinbaseApiKeyId = "26db7037-4eee-498a-9d71-bd6fe7bedfd5"
    private static let embeddedCoinbaseApiKeySecret = "1rqxGT0diJII3UR2VsbH7nX8gxfMFM9w2X0D9uqXINGdhfoB0/Md1z5CZw97x8fmUFu1XUqqj6gPUl1GKrgVBg=="

    /// In-memory configuration container (optional override).
    public struct Configuration {
        public let apiKeyId: String
        public let apiKeySecret: String
    }

    /// The currently configured settings, if any.
    public private(set) static var configuration: Configuration?

    /// Effective Coinbase API key ID (uses embedded default if no override).
    public static var coinbaseApiKeyId: String {
        configuration?.apiKeyId ?? embeddedCoinbaseApiKeyId
    }

    /// Effective Coinbase API key secret (uses embedded default if no override).
    public static var coinbaseApiKeySecret: String {
        configuration?.apiKeySecret ?? embeddedCoinbaseApiKeySecret
    }

    /// Configure ZeroSettleKit once at app launch (optional override).
    /// If not called, the embedded WordPlay demo credentials are used.
    public static func configure(apiKeyId: String, apiKeySecret: String) {
        configuration = Configuration(apiKeyId: apiKeyId, apiKeySecret: apiKeySecret)
#if DEBUG
        print("[ZeroSettleKit] Configured with API key id (len: \(apiKeyId.count)) and secret (len: \(apiKeySecret.count))")
#endif
    }

    /// Convenience configuration using the embedded WordPlay demo credentials.
    public static func configureWithWordPlayDemoKey() {
        configuration = Configuration(apiKeyId: embeddedCoinbaseApiKeyId, apiKeySecret: embeddedCoinbaseApiKeySecret)
#if DEBUG
        print("[ZeroSettleKit] Configured with embedded WordPlay demo credentials")
#endif
    }
}

