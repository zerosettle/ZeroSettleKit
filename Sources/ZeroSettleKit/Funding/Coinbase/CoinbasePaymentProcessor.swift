import Foundation

/// Coinbase Commerce payment processor for Apple Pay → USDC onramp
public class CoinbasePaymentProcessor: PaymentProcessor {

    // MARK: - Configuration

    private let apiKeyId: String
    private let apiKeySecret: String
    private let environment: CoinbaseEnvironment

    // MARK: - PaymentProcessor Protocol

    public var supportedMethods: [PaymentMethod] {
        [.applePay, .creditCard, .debitCard]
    }

    // MARK: - Initialization

    public init(apiKeyId: String, apiKeySecret: String, environment: CoinbaseEnvironment = .production) {
        self.apiKeyId = apiKeyId
        self.apiKeySecret = apiKeySecret
        self.environment = environment
        print("CoinbasePaymentProcessor initialized (\(environment.rawValue))")
    }

    // MARK: - PaymentProcessor Methods

    public func initiateFunding(
        amount: Decimal,
        currency: String,
        destination: String,
        network: BlockchainNetwork
    ) async throws -> FundingSession {
        print("[Coinbase] Initiating funding: \(amount) \(currency) to \(destination) on \(network.rawValue)")

        // Convert network to Coinbase network name
        let coinbaseNetwork = try mapNetworkToCoinbase(network)

        // Build request body
        let requestBody: [String: Any] = [
            "agreementAcceptedAt": ISO8601DateFormatter().string(from: Date()),
            "destinationAddress": destination,
            "destinationNetwork": coinbaseNetwork,
            "email": "user@example.com", // Apps should provide this
            "isQuote": false,
            "partnerUserRef": environment == .sandbox ? "sandbox-user-\(UUID().uuidString.prefix(8))" : "user-\(UUID().uuidString.prefix(8))",
            "paymentAmount": String(format: "%.2f", (amount as NSDecimalNumber).doubleValue),
            "paymentCurrency": currency,
            "paymentMethod": "GUEST_CHECKOUT_APPLE_PAY",
            "phoneNumber": "+12055555555", // Apps should provide this
            "phoneNumberVerifiedAt": ISO8601DateFormatter().string(from: Date()),
            "purchaseCurrency": "USDC"
        ]

        // Generate JWT token
        let requestMethod = "POST"
        let requestHost = environment.apiHost
        let requestPath = "/platform/v2/onramp/orders"

        let jwtToken: String
        do {
            jwtToken = try CoinbaseJWTGenerator.generateJWT(
                requestMethod: requestMethod,
                requestHost: requestHost,
                requestPath: requestPath,
                apiKeyId: apiKeyId,
                apiKeySecret: apiKeySecret
            )
            print("[Coinbase] Generated JWT token")
        } catch {
            print("[Coinbase] Failed to generate JWT: \(error)")
            throw CoinbaseError.jwtGenerationFailed(error)
        }

        // Create the API request
        guard let url = URL(string: "https://\(requestHost)\(requestPath)") else {
            throw CoinbaseError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = requestMethod
        request.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("[Coinbase] Making request to: \(url.absoluteString)")

        // Make the API call
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoinbaseError.invalidResponse
        }

        print("[Coinbase] Response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            // Try to parse error response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = json["errorMessage"] as? String {
                throw CoinbaseError.apiError(errorMsg)
            }
            throw CoinbaseError.httpError(httpResponse.statusCode)
        }

        // Parse the response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let order = json["order"] as? [String: Any],
              let orderId = order["orderId"] as? String,
              let paymentLink = json["paymentLink"] as? [String: Any],
              let paymentURLString = paymentLink["url"] as? String,
              let paymentURL = URL(string: paymentURLString) else {
            throw CoinbaseError.invalidResponse
        }

        print("[Coinbase] Payment URL received: \(paymentURLString)")
        print("[Coinbase] Order ID: \(orderId)")

        return FundingSession(
            paymentURL: paymentURL,
            sessionId: orderId,
            amount: amount,
            currency: currency,
            destinationAddress: destination,
            network: network,
            metadata: [
                "coinbase_order_id": orderId,
                "environment": environment.rawValue
            ]
        )
    }

    public func handlePaymentEvent(_ event: PaymentEvent) async throws {
        switch event {
        case .initiated:
            print("[Coinbase] Payment initiated")
        case .pending:
            print("[Coinbase] Payment pending")
        case .success(let txHash):
            print("[Coinbase] Payment successful! TX: \(txHash ?? "unknown")")
        case .failed(let error):
            print("[Coinbase] Payment failed: \(error.localizedDescription)")
        case .cancelled:
            print("[Coinbase] Payment cancelled")
        }
    }

    // MARK: - Helper Methods

    private func mapNetworkToCoinbase(_ network: BlockchainNetwork) throws -> String {
        switch network {
        case .base: return "base"
        case .ethereum: return "ethereum"
        case .polygon: return "polygon"
        case .arbitrum: return "arbitrum"
        case .optimism: return "optimism"
        case .solana: return "solana"
        }
    }
}

// MARK: - Coinbase Environment

public enum CoinbaseEnvironment: String {
    case sandbox = "sandbox"
    case production = "production"

    var apiHost: String {
        switch self {
        case .sandbox, .production:
            return "api.cdp.coinbase.com"
        }
    }
}

// MARK: - Errors

public enum CoinbaseError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case jwtGenerationFailed(Error)
    case apiError(String)
    case httpError(Int)
    case unsupportedNetwork

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Coinbase API URL"
        case .invalidResponse:
            return "Invalid response from Coinbase"
        case .jwtGenerationFailed(let error):
            return "Failed to generate JWT: \(error.localizedDescription)"
        case .apiError(let message):
            return "Coinbase API error: \(message)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .unsupportedNetwork:
            return "Blockchain network not supported by Coinbase"
        }
    }
}
