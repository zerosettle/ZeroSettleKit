// URL+Redacted.swift
//
// Helpers for safely logging URLs without leaking sensitive data via query
// strings or fragments.
//
// Backend redirect templates put `client_secret`, `user_id`, `transaction_id`,
// and `original_transaction_id` in URL query / fragment. Logging the full
// `url.absoluteString` writes those into device logs (and, with the
// ZSLogger redaction in DEBUG builds, into Console.app where any reader
// can see them). This extension drops query and fragment, leaving only
// scheme + host + path — enough for triage, nothing privacy-sensitive.

import Foundation

extension URL {
    /// A redacted form of the URL safe for logging. Drops query string and
    /// fragment; preserves scheme, host, and path. If the URL can't be
    /// parsed, returns a placeholder so the log line stays useful for
    /// diagnostics without echoing the raw input.
    public var redactedForLogs: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "<unparseable URL>"
        }
        components.query = nil
        components.fragment = nil
        components.queryItems = nil
        components.password = nil
        components.user = nil
        return components.string ?? "<unparseable URL>"
    }
}
