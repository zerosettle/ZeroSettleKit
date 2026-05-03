//
//  CheckoutResponseCache.swift
//  ZeroSettleKit
//
//  Global cache for CheckoutResponse objects. Stores the full server response
//  so any checkout consumer (WebView, NativePay, Migration) gets an instant
//  cache hit after preloading. Coalesces concurrent requests for the same
//  product so only one PI is created per preload window.
//

import Foundation

#if canImport(ZeroSettleCore)
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif
#endif

internal actor CheckoutResponseCache {
    static let shared = CheckoutResponseCache()

    private struct Entry {
        let response: CheckoutResponse
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<CheckoutResponse?, Never>] = [:]
    private let ttl: TimeInterval = 300 // 5 minutes

    /// Cache key includes the publishable key so entries from one environment
    /// (sandbox vs live) are never served after an environment switch.
    private func cacheKey(productId: String, userId: String?, publishableKey: String) -> String {
        "\(publishableKey):\(productId):\(userId ?? "")"
    }

    // MARK: - Read

    /// Non-destructive read. Use for WebView preloading where you need the URL
    /// but don't want to consume the entry.
    func get(productId: String, userId: String?, publishableKey: String = "") -> CheckoutResponse? {
        let key = cacheKey(productId: productId, userId: userId, publishableKey: publishableKey)
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.timestamp) < ttl else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.response
    }

    /// Convenience accessor for callers that only need the checkout URL and transaction ID.
    func getURLAndTransactionId(productId: String, userId: String?, publishableKey: String = "") -> (checkoutURL: URL, transactionId: String)? {
        guard let response = get(productId: productId, userId: userId, publishableKey: publishableKey),
              let url = URL(string: response.checkoutUrl) else {
            return nil
        }
        return (url, response.transactionId)
    }

    // MARK: - Coalesced Fetch

    /// Returns a cached response, joins an in-flight request, or starts a new one.
    ///
    /// This is the primary API for preloading. If another caller is already fetching
    /// the same product, this awaits that request instead of creating a duplicate.
    func fetchOrJoin(
        productId: String,
        userId: String?,
        publishableKey: String = "",
        loader: @Sendable @escaping () async -> CheckoutResponse?
    ) async -> CheckoutResponse? {
        let key = cacheKey(productId: productId, userId: userId, publishableKey: publishableKey)

        // 1. Cache hit
        if let entry = entries[key], Date().timeIntervalSince(entry.timestamp) < ttl {
            return entry.response
        }
        entries.removeValue(forKey: key)

        // 2. Join in-flight request
        if let existing = inFlight[key] {
            return await existing.value
        }

        // 3. Start new request
        let task = Task<CheckoutResponse?, Never> { await loader() }
        inFlight[key] = task

        let response = await task.value
        inFlight.removeValue(forKey: key)

        if let response {
            entries[key] = Entry(response: response, timestamp: Date())
        } else {
            ZSLogger.error("[Checkout] PI creation failed for \(productId)", category: .checkout)
        }
        return response
    }

    // MARK: - Consume

    /// Destructive read: returns the cached response and removes it from the cache.
    /// Use at presentation time so subsequent views get a fresh server call.
    func consume(productId: String, userId: String?, publishableKey: String = "") -> CheckoutResponse? {
        let key = cacheKey(productId: productId, userId: userId, publishableKey: publishableKey)
        guard let entry = entries.removeValue(forKey: key),
              Date().timeIntervalSince(entry.timestamp) < ttl else {
            return nil
        }
        return entry.response
    }

    // MARK: - Write

    func set(productId: String, userId: String?, publishableKey: String = "", response: CheckoutResponse) {
        let key = cacheKey(productId: productId, userId: userId, publishableKey: publishableKey)
        entries[key] = Entry(response: response, timestamp: Date())
    }

    // MARK: - Invalidate

    func invalidate(productId: String, userId: String?, publishableKey: String = "") {
        entries.removeValue(forKey: cacheKey(productId: productId, userId: userId, publishableKey: publishableKey))
    }

    /// Remove all cached entries. Called on SDK reconfiguration to prevent
    /// stale entries from a different environment being served.
    func clearAll() {
        entries.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }
}
