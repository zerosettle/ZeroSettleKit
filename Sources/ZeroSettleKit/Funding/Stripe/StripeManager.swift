//
//  StripeManager.swift
//  ZeroSettleKit
//
//  Handles Stripe payment session callbacks via deeplink
//

import Foundation
import Combine

/// Manages Stripe payment session state and callbacks
@MainActor
public final class StripeManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = StripeManager()

    // MARK: - Published Properties

    /// The last session ID received
    @Published public private(set) var lastSessionId: String?

    /// The last payment status
    @Published public private(set) var lastStatus: PaymentStatus?

    // MARK: - Callbacks

    /// Callback when payment succeeds
    public var onPaymentSuccess: ((String) -> Void)?  // Called with session_id

    /// Callback when payment is cancelled
    public var onPaymentCancelled: (() -> Void)?

    // MARK: - Payment Status

    public enum PaymentStatus: String {
        case success
        case cancelled
    }

    // MARK: - Initialization

    private init() {
        print("[Stripe] StripeManager initialized")
    }

    // MARK: - URL Handling

    /// Handle incoming deeplink URL from Stripe redirect
    /// Expected format: wordplay://stripe/success?session_id=cs_xxx&status=success
    /// Or: wordplay://stripe/cancel?status=cancelled
    public func handleUrl(_ url: URL) -> Bool {
        guard url.scheme == "wordplay",
              url.host == "stripe" else {
            return false
        }

        print("[Stripe] Handling redirect URL: \(url.absoluteString)")

        // Parse path and query params
        let path = url.path
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            print("[Stripe] Could not parse URL components")
            return false
        }

        // Extract query params
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        // Handle success
        if path.contains("success") {
            if let sessionId = params["session_id"],
               let status = params["status"],
               status == "success" {
                print("[Stripe] Payment successful - Session ID: \(sessionId)")
                self.lastSessionId = sessionId
                self.lastStatus = .success
                self.onPaymentSuccess?(sessionId)
                return true
            }
        }

        // Handle cancel
        if path.contains("cancel") {
            if let status = params["status"],
               status == "cancelled" {
                print("[Stripe] Payment cancelled")
                self.lastStatus = .cancelled
                self.onPaymentCancelled?()
                return true
            }
        }

        print("[Stripe] Unrecognized path or params")
        return false
    }

    // MARK: - Reset

    public func reset() {
        lastSessionId = nil
        lastStatus = nil
    }
}
