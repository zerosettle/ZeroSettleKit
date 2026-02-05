//
//  ZeroSettleIAP.swift
//  ZeroSettleIAP
//
//  Main entry point for the ZeroSettle IAP SDK.
//  Provides web checkout for in-app purchases via Stripe.
//

import Foundation
import StoreKit

#if canImport(ZeroSettleCore)
import ZeroSettleCore
#endif

// MARK: - Errors

public enum ZeroSettleIAPError: Error, LocalizedError {
    case notConfigured
    case invalidPublishableKey
    case productNotFound(String)
    case checkoutSessionFailed(String)
    case transactionVerificationFailed(String)
    case networkError(Error)
    case invalidCallbackURL

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ZeroSettleIAP is not configured. Call configure() first."
        case .invalidPublishableKey:
            return "Invalid publishable key. Check your ZeroSettle dashboard."
        case .productNotFound(let productId):
            return "Product not found: \(productId)"
        case .checkoutSessionFailed(let message):
            return "Failed to create checkout session: \(message)"
        case .transactionVerificationFailed(let message):
            return "Transaction verification failed: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidCallbackURL:
            return "Invalid checkout callback URL."
        }
    }
}

// MARK: - ZeroSettle IAP

/// Main entry point for the ZeroSettle IAP SDK.
/// Handles web checkout, entitlement management, and StoreKit transaction syncing.
@MainActor
public final class ZeroSettleIAP: ObservableObject {

    // MARK: - Singleton

    public static let shared = ZeroSettleIAP()

    #if DEBUG
    /// Override the backend base URL for local development.
    /// Only available in debug builds. Set before calling `configure()`.
    public nonisolated(unsafe) static var baseURLOverride: URL?
    #endif

    // MARK: - Configuration

    /// Configuration for the ZeroSettle IAP SDK.
    public struct Configuration: Sendable {
        /// Your publishable key from the ZeroSettle dashboard (e.g., "pk_live_abc123")
        public let publishableKey: String

        /// Network environment for the backend API
        public let environment: NetworkEnvironment

        /// Whether to listen for and forward native StoreKit transactions to ZeroSettle.
        /// Set to `false` if you use RevenueCat (which handles StoreKit reporting itself).
        /// Defaults to `true`.
        public let syncStoreKitTransactions: Bool

        public init(
            publishableKey: String,
            environment: NetworkEnvironment = .production,
            syncStoreKitTransactions: Bool = true
        ) {
            self.publishableKey = publishableKey
            self.environment = environment
            self.syncStoreKitTransactions = syncStoreKitTransactions
        }

        internal var backendURL: URL { environment.backendURL }
    }

    // MARK: - Published State

    /// Whether the SDK has been configured.
    @Published public private(set) var isConfigured: Bool = false

    /// Cached products from the last `fetchProducts()` call.
    @Published public private(set) var products: [Product] = []

    /// Current entitlements (merged from StoreKit and web checkout sources).
    @Published public private(set) var entitlements: [Entitlement] = []

    /// Whether a web checkout is currently in progress (user is in Safari).
    @Published public private(set) var pendingCheckout: Bool = false

    /// Remote configuration from the backend (populated after `fetchProducts()`).
    /// Contains checkout type settings and optional migration campaign data.
    @Published public private(set) var remoteConfig: RemoteConfig?

    // MARK: - Computed Properties

    /// The configured checkout type. Returns `.safari` as the default fallback
    /// if remote config hasn't been fetched yet.
    public var checkoutType: CheckoutType {
        remoteConfig?.checkout.sheetType ?? .safari
    }

    // MARK: - Delegate

    /// Delegate to receive IAP event callbacks.
    public weak var delegate: ZeroSettleIAPDelegate?

    // MARK: - Internal State (for ZeroSettleCheckoutView)

    /// Internal accessor for the current configuration.
    /// Used by `ZeroSettleCheckoutView` to create checkout sessions.
    internal var currentConfig: Configuration? { config }

    /// The effective base URL, accounting for any debug override.
    /// Used by `ZeroSettleCheckoutView` to ensure it uses the same backend URL.
    internal var effectiveBaseURL: URL? {
        guard let config else { return nil }
        #if DEBUG
        return Self.baseURLOverride ?? config.backendURL
        #else
        return config.backendURL
        #endif
    }

    // MARK: - Private State

    private var config: Configuration?
    private var backend: Backend?
    private var checkoutFlow: WebCheckoutFlow?
    private var storeKitManager: StoreKitManager?
    private var pendingTransactionId: String?

    // MARK: - Initialization

    private init() {
        Logger.info("ZeroSettleIAP initialized", category: .iap)
    }

    // MARK: - Configuration

    /// Configure the SDK. Must be called before any other methods.
    /// - Parameter config: The IAP configuration with your publishable key
    public func configure(_ config: Configuration) {
        self.config = config

        #if DEBUG
        let baseURL = Self.baseURLOverride ?? config.backendURL
        #else
        let baseURL = config.backendURL
        #endif

        let backend = Backend(baseURL: baseURL, publishableKey: config.publishableKey)
        self.backend = backend

        let checkoutFlow = WebCheckoutFlow(backend: backend)
        self.checkoutFlow = checkoutFlow

        if config.syncStoreKitTransactions {
            let storeKitManager = StoreKitManager(backend: backend)
            storeKitManager.delegate = self
            storeKitManager.startListening()
            self.storeKitManager = storeKitManager
        }

        isConfigured = true
        Logger.info("ZeroSettleIAP configured for \(config.environment.rawValue)", category: .iap)
    }

    // MARK: - Products

    /// Fetch the product catalog from ZeroSettle with web checkout pricing.
    /// Also reconciles with StoreKit products for native purchasing support.
    /// Results are cached in the `products` and `remoteConfig` published properties.
    ///
    /// - Parameter userId: Optional user ID to check for migration eligibility.
    ///   Pass this to receive migration campaign data in `remoteConfig.migration`.
    /// - Returns: Array of products with web prices, StoreKit prices, and any active promotions
    @discardableResult
    public func fetchProducts(userId: String? = nil) async throws -> [Product] {
        guard let backend else {
            throw ZeroSettleIAPError.notConfigured
        }

        do {
            // 1. Fetch from ZeroSettle backend (includes config when userId is provided)
            let (fetchedProducts, config) = try await backend.fetchProducts(userId: userId)
            var products = fetchedProducts
            Logger.info("Fetched \(products.count) products from backend", category: .iap)

            // Store remote config if present
            if let config {
                remoteConfig = config
                Logger.info("Remote config received: checkoutType=\(config.checkout.sheetType.rawValue), migration=\(config.migration != nil)", category: .iap)
            }

            // 2. Try to fetch ALL products from StoreKit (let StoreKit tell us what exists)
            let allProductIds = products.map { $0.id }

            // 3. Fetch StoreKit products (if StoreKit sync enabled)
            if let storeKitManager, !allProductIds.isEmpty {
                let skProducts = await storeKitManager.fetchProducts(for: allProductIds)

                // 4. Attach StoreKit products to our Product models
                // Products that exist in StoreKit get _storeKitProduct populated
                // Products that don't exist remain web-only
                for i in products.indices {
                    if let skProduct = skProducts[products[i].id] {
                        products[i]._storeKitProduct = skProduct
                    }
                }

                let matched = products.filter { $0.storeKitAvailable }.count
                Logger.info("Reconciled \(matched)/\(products.count) products with StoreKit", category: .iap)
            }

            self.products = products
            return products
        } catch {
            Logger.error("Failed to fetch products: \(error)", category: .iap)
            throw ZeroSettleIAPError.networkError(error)
        }
    }

    // MARK: - Purchase

    /// Initiate a web checkout for the given product.
    /// This opens Safari with the Stripe checkout page. The result will come back
    /// via the universal link callback (see `handleUniversalLink(_:)`).
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: Your app's user identifier (must match RevenueCat app user ID if using RC)
    public func purchase(productId: String, userId: String) async throws {
        guard let checkoutFlow else {
            throw ZeroSettleIAPError.notConfigured
        }

        // Update StoreKit manager with user ID for future sync operations
        storeKitManager?.setUserId(userId)

        do {
            let session = try await checkoutFlow.beginCheckout(
                productId: productId,
                userId: userId
            )

            pendingTransactionId = session.transactionId
            pendingCheckout = true
            delegate?.zeroSettleIAPCheckoutDidBegin(productId: productId)

            Logger.info("Checkout started for \(productId), transaction: \(session.transactionId)", category: .iap)
        } catch {
            Logger.error("Checkout failed for \(productId): \(error)", category: .iap)
            delegate?.zeroSettleIAPCheckoutDidFail(productId: productId, error: error)
            throw ZeroSettleIAPError.checkoutSessionFailed(error.localizedDescription)
        }
    }

    /// Purchase a product via native StoreKit 2.
    /// Use this for products synced to App Store Connect where `storeKitAvailable` is true.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: Your app's user ID (for syncing the transaction to ZeroSettle backend)
    /// - Returns: The StoreKit transaction
    public func purchaseViaStoreKit(productId: String, userId: String) async throws -> StoreKit.Transaction {
        guard let storeKitManager else {
            throw ZeroSettleIAPError.notConfigured
        }

        guard let product = products.first(where: { $0.id == productId }) else {
            throw ZeroSettleIAPError.productNotFound(productId)
        }

        guard let skProduct = product._storeKitProduct else {
            throw StoreKitPurchaseError.productNotFound(productId)
        }

        storeKitManager.setUserId(userId)
        return try await storeKitManager.purchase(skProduct)
    }

    // MARK: - Migration Tracking

    /// Track a successful migration conversion.
    /// Call this after a user successfully completes a web checkout purchase
    /// as part of a migration campaign (switching from StoreKit to web checkout).
    ///
    /// - Parameter userId: Your app's user identifier
    public func trackMigrationConversion(userId: String) async throws {
        guard let backend else {
            throw ZeroSettleIAPError.notConfigured
        }

        do {
            try await backend.trackMigrationConversion(userId: userId)
            Logger.info("Migration conversion tracked for user: \(userId)", category: .iap)
        } catch {
            Logger.error("Failed to track migration conversion: \(error)", category: .iap)
            throw ZeroSettleIAPError.networkError(error)
        }
    }

    // MARK: - Universal Link Handling

    /// Handle a universal link callback from the web checkout.
    /// Call this from your SceneDelegate's `scene(_:continue:)` or
    /// AppDelegate's `application(_:continue:restorationHandler:)`.
    ///
    /// - Parameter url: The universal link URL
    /// - Returns: `true` if the URL was handled by ZeroSettleIAP, `false` otherwise
    @discardableResult
    public func handleUniversalLink(_ url: URL) -> Bool {
        Logger.info("Handling universal link redirect")

        guard let checkoutFlow else {
            Logger.error("handleUniversalLink called but SDK not configured", category: .iap)
            return false
        }

        guard let callback = checkoutFlow.handleCallback(url: url) else {
            return false
        }

        // Dismiss SFSafariViewController if it was used
        checkoutFlow.dismissSafariViewController()

        // Process the callback asynchronously
        Task {
            await processCheckoutCallback(callback)
        }

        return true
    }

    // MARK: - Entitlements

    /// Restore entitlements from both ZeroSettle backend and StoreKit.
    /// Call this on app launch to recover from missed deeplinks or to sync state.
    ///
    /// - Parameter userId: Your app's user identifier
    /// - Returns: The merged entitlements from all sources
    @discardableResult
    public func restoreEntitlements(userId: String) async throws -> [Entitlement] {
        guard let backend else {
            throw ZeroSettleIAPError.notConfigured
        }

        // Update StoreKit manager with user ID
        storeKitManager?.setUserId(userId)

        var allEntitlements: [Entitlement] = []

        // Fetch web checkout entitlements from ZeroSettle backend
        do {
            let webEntitlements = try await backend.getEntitlements(userId: userId)
            allEntitlements.append(contentsOf: webEntitlements)
            Logger.info("Restored \(webEntitlements.count) web entitlements", category: .iap)
        } catch {
            Logger.error("Failed to fetch web entitlements: \(error)", category: .iap)
        }

        // Fetch StoreKit entitlements if sync is enabled
        if let storeKitManager {
            let storeKitEntitlements = await storeKitManager.getCurrentEntitlements()
            allEntitlements.append(contentsOf: storeKitEntitlements)
            Logger.info("Restored \(storeKitEntitlements.count) StoreKit entitlements", category: .iap)
        }

        entitlements = allEntitlements
        delegate?.zeroSettleIAPEntitlementsDidUpdate(allEntitlements)

        return allEntitlements
    }

    // MARK: - Private

    /// Process a checkout callback after the universal link is received.
    private func processCheckoutCallback(_ callback: CheckoutCallback) async {
        pendingCheckout = false

        guard callback.success else {
            Logger.info("Checkout cancelled for product: \(callback.productId)", category: .iap)
            delegate?.zeroSettleIAPCheckoutDidCancel(productId: callback.productId)
            pendingTransactionId = nil
            return
        }

        // Verify the transaction with the backend
        guard let backend else { return }

        do {
            let transaction = try await backend.getTransaction(transactionId: callback.transactionId)

            guard transaction.status == .completed else {
                let error = ZeroSettleIAPError.transactionVerificationFailed(
                    "Transaction status: \(transaction.status.rawValue)"
                )
                delegate?.zeroSettleIAPCheckoutDidFail(productId: callback.productId, error: error)
                pendingTransactionId = nil
                return
            }

            Logger.info("Checkout completed: \(transaction.id) for \(transaction.productId)", category: .iap)
            delegate?.zeroSettleIAPCheckoutDidComplete(transaction: transaction)

            // Fetch fresh entitlements from backend to get proper expiry dates
            // This ensures subscription expiresAt is populated correctly from the server
            if let userId = storeKitManager?.currentUserId {
                do {
                    let freshEntitlements = try await backend.getEntitlements(userId: userId)
                    // Merge: keep StoreKit entitlements, add/replace web entitlements
                    let storeKitEnts = entitlements.filter { $0.source == .storeKit }
                    entitlements = storeKitEnts + freshEntitlements
                    delegate?.zeroSettleIAPEntitlementsDidUpdate(entitlements)
                    Logger.info("Refreshed entitlements after checkout: \(freshEntitlements.count) web entitlements", category: .iap)
                } catch {
                    Logger.error("Failed to refresh entitlements after checkout: \(error)", category: .iap)
                    // Fall back to creating local entitlement with available info
                    let entitlement = Entitlement(
                        id: "web_\(transaction.id)",
                        productId: transaction.productId,
                        source: .webCheckout,
                        isActive: true,
                        expiresAt: transaction.expiresAt,
                        purchasedAt: transaction.purchasedAt
                    )
                    entitlements.append(entitlement)
                    delegate?.zeroSettleIAPEntitlementsDidUpdate(entitlements)
                }
            } else {
                // No user ID available, create local entitlement
                let entitlement = Entitlement(
                    id: "web_\(transaction.id)",
                    productId: transaction.productId,
                    source: .webCheckout,
                    isActive: true,
                    expiresAt: transaction.expiresAt,
                    purchasedAt: transaction.purchasedAt
                )
                entitlements.append(entitlement)
                delegate?.zeroSettleIAPEntitlementsDidUpdate(entitlements)
            }

        } catch {
            Logger.error("Transaction verification failed: \(error)", category: .iap)
            delegate?.zeroSettleIAPCheckoutDidFail(
                productId: callback.productId,
                error: ZeroSettleIAPError.transactionVerificationFailed(error.localizedDescription)
            )
        }

        pendingTransactionId = nil
    }
}

// MARK: - StoreKit Update Delegate

extension ZeroSettleIAP: StoreKitUpdateDelegate {
    nonisolated func storeKitDidSyncTransaction(productId: String, transactionId: UInt64) {
        Task { @MainActor in
            delegate?.zeroSettleIAPDidSyncStoreKitTransaction(
                productId: productId,
                transactionId: transactionId
            )
        }
    }

    nonisolated func storeKitSyncFailed(error: Error) {
        Task { @MainActor in
            delegate?.zeroSettleIAPStoreKitSyncFailed(error: error)
        }
    }

    nonisolated func storeKitEntitlementsDidChange(_ entitlements: [Entitlement]) {
        Task { @MainActor in
            // Merge: keep web entitlements, replace StoreKit entitlements
            let webEntitlements = self.entitlements.filter { $0.source == .webCheckout }
            self.entitlements = webEntitlements + entitlements
            delegate?.zeroSettleIAPEntitlementsDidUpdate(self.entitlements)
        }
    }
}
