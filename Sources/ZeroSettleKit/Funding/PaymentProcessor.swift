import Foundation

/// Protocol for payment processors that handle fiat-to-crypto onramp
public protocol PaymentProcessor {
    /// The supported payment methods for this processor
    var supportedMethods: [PaymentMethod] { get }

    /// Initiate a funding transaction
    /// - Parameters:
    ///   - amount: The amount in fiat currency
    ///   - currency: The fiat currency (e.g., "USD")
    ///   - destination: The destination wallet address
    ///   - network: The blockchain network
    /// - Returns: A funding session containing payment URL and metadata
    func initiateFunding(
        amount: Decimal,
        currency: String,
        destination: String,
        network: BlockchainNetwork
    ) async throws -> FundingSession

    /// Handle a payment event from the processor
    /// - Parameter event: The payment event
    func handlePaymentEvent(_ event: PaymentEvent) async throws
}

/// Supported payment methods
public enum PaymentMethod: String, Codable {
    case applePay = "APPLE_PAY"
    case googlePay = "GOOGLE_PAY"
    case creditCard = "CREDIT_CARD"
    case debitCard = "DEBIT_CARD"
    case bankTransfer = "BANK_TRANSFER"
}

/// A funding session created by a payment processor
public struct FundingSession {
    /// The payment URL to load in a web view
    public let paymentURL: URL

    /// The unique session/order ID
    public let sessionId: String

    /// The amount being funded
    public let amount: Decimal

    /// The currency
    public let currency: String

    /// The destination address
    public let destinationAddress: String
    
    /// The blockchain network
    public let network: BlockchainNetwork

    /// Additional metadata from the processor
    public let metadata: [String: String]?

    public init(
        paymentURL: URL,
        sessionId: String,
        amount: Decimal,
        currency: String,
        destinationAddress: String,
        network: BlockchainNetwork,
        metadata: [String: String]? = nil
    ) {
        self.paymentURL = paymentURL
        self.sessionId = sessionId
        self.amount = amount
        self.currency = currency
        self.destinationAddress = destinationAddress
        self.network = network
        self.metadata = metadata
    }
}

/// Payment events from processors
public enum PaymentEvent {
    case initiated
    case pending
    case success(transactionHash: String?)
    case failed(error: Error)
    case cancelled
}
