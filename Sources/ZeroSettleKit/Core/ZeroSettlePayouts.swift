import Foundation

// MARK: - Lightweight Payout Fetcher

/// Convenience helper for fetching partner payout tables without instantiating the full manager.
public enum ZeroSettlePayouts {
    /// Fetch the most recent payout table for a partner app.
    /// - Parameters:
    ///   - partnerAppId: Partner application identifier (defaults to WordPlay's app id `2`)
    ///   - baseURL: Base API URL (defaults to production)
    ///   - authTokenProvider: Optional provider for partner auth tokens (Bearer)
    public static func fetchLatest(
        partnerAppId: Int = 2,
        baseURL: URL = URL(string: "https://zerosettle.io/api/v1")!,
        authTokenProvider: (() -> String?)? = nil
    ) async throws -> ZeroSettlePayoutTable {
        let config = ZeroSettleConfig(
            privyAppId: "",
            privyClientId: "",
            paymentProcessor: ReadOnlyPaymentProcessor(),
            apiBaseURL: baseURL,
            partnerAppId: partnerAppId,
            partnerAuthTokenProvider: authTokenProvider
        )

        let service = PayoutTableService(config: config)
        return try await service.fetchLatestPayoutTable()
    }
}

// MARK: - Internal Helpers

struct ReadOnlyPaymentProcessor: PaymentProcessor {
    var supportedMethods: [PaymentMethod] { [] }

    func initiateFunding(
        amount: Decimal,
        currency: String,
        destination: String,
        network: BlockchainNetwork
    ) async throws -> FundingSession {
        throw ZeroSettleReadOnlyError.fundingUnavailable
    }

    func handlePaymentEvent(_ event: PaymentEvent) async throws {
        // No-op
    }
}

enum ZeroSettleReadOnlyError: Error {
    case fundingUnavailable
}

