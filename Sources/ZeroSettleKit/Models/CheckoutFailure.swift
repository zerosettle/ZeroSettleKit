import Foundation

/// Reasons checkout might fail to load.
///
/// Surfaced via `ZSMigrationManager.onCheckoutFailure` callback. SDK is
/// unopinionated about UX — consuming app pattern-matches and decides
/// whether to log, retry, toast, or ignore.
public enum CheckoutFailure: Error {
    /// Network unreachable, DNS failure, certificate issue — fired before
    /// any HTTP response is received.
    case networkUnreachable(Error)

    /// Load started but errored mid-flight.
    case loadFailed(Error)

    /// Server returned an HTTP error response (4xx/5xx).
    case serverError(statusCode: Int, url: URL)

    /// Anything else not covered above.
    case unknown(Error)
}

extension CheckoutFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .networkUnreachable(let err):
            return "Network unreachable: \(err.localizedDescription)"
        case .loadFailed(let err):
            return "Load failed: \(err.localizedDescription)"
        case .serverError(let code, let url):
            return "Server error \(code) at \(url)"
        case .unknown(let err):
            return "Unknown failure: \(err.localizedDescription)"
        }
    }
}
