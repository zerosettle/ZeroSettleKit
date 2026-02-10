//
//  ZeroSettleIAP.swift
//  ZeroSettleIAP
//
//  Main entry point for the ZeroSettle IAP SDK.
//  Provides web checkout for in-app purchases via Stripe.
//

import Foundation
import StoreKit
import SwiftUI

#if canImport(ZeroSettleCore)
import ZeroSettleCore
#endif

// MARK: - Supporting Error Types

/// Structured detail for API/HTTP errors at the product boundary.
/// Preserves the HTTP status code, server-provided error message, and error code
/// so developers can take targeted action (e.g., retry on 503, show message on 422).
public struct APIErrorDetail: Error, LocalizedError, Sendable {
    /// HTTP status code from the server response, if available.
    public let statusCode: Int?
    /// Human-readable error message parsed from the response body.
    public let serverMessage: String?
    /// Machine-readable error code parsed from the response body (e.g., "product_not_found").
    public let serverCode: String?
    /// The original error that was thrown by the networking layer.
    public let underlyingError: any Error

    public var errorDescription: String? {
        if let serverMessage {
            return serverMessage
        }
        if let statusCode {
            return "Server error (\(statusCode))"
        }
        return underlyingError.localizedDescription
    }
}

/// Classifies checkout failures into actionable categories.
///
/// Use this to distinguish between card declines, server errors, and network issues
/// when handling ``ZSError/checkoutFailed(reason:)``.
public enum CheckoutFailure: Sendable {
    /// The requested product was not found on the server.
    case productNotFound
    /// The merchant has not completed Stripe onboarding.
    case merchantNotOnboarded
    /// Stripe returned an error (e.g., card declined, insufficient funds).
    case stripeError(code: String?, message: String)
    /// The server returned a non-2xx response.
    case serverError(statusCode: Int, message: String?)
    /// The device appears to have no network connectivity.
    case networkUnavailable
    /// An unclassified error occurred.
    case other(String)
}

// MARK: - Errors

/// Unified error type for the ZeroSettle IAP SDK.
///
/// All public methods throw `ZSError`. Match on specific cases to handle
/// different failure modes:
/// ```swift
/// do {
///     try await ZeroSettleIAP.shared.purchase(productId: "premium", userId: "user_42")
/// } catch let error as ZSError {
///     switch error {
///     case .notConfigured: // SDK not set up
///     case .cancelled: // User cancelled
///     case .checkoutFailed(let reason): // Payment failure
///     case .apiError(let detail): // Network/server error
///     default: break
///     }
/// }
/// ```
public enum ZSError: Error, LocalizedError {
    /// The SDK has not been configured. Call ``ZeroSettleIAP/configure(_:)`` first.
    case notConfigured

    /// The publishable key format is invalid.
    case invalidPublishableKey

    /// No product found with the given identifier.
    case productNotFound(String)

    /// The checkout flow failed for a specific reason.
    case checkoutFailed(reason: CheckoutFailure)

    /// Transaction verification failed after checkout.
    case transactionVerificationFailed(String)

    /// An API or network error occurred.
    case apiError(APIErrorDetail)

    /// The checkout callback URL could not be parsed.
    case invalidCallbackURL

    /// Web checkout is disabled for the user's jurisdiction.
    case webCheckoutDisabledForJurisdiction(Jurisdiction)

    /// A `userId` is required for this product type (subscriptions, non-consumables).
    case userIdRequired(productId: String)

    /// Entitlement restoration partially failed. Check `partialEntitlements` for what was recovered.
    case restoreEntitlementsFailed(partialEntitlements: [Entitlement], underlyingError: Error)

    /// The user cancelled the purchase.
    case cancelled

    /// The purchase is pending approval (e.g., Ask to Buy).
    case purchasePending

    /// A StoreKit transaction failed verification.
    case storeKitVerificationFailed(underlyingError: Error)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ZeroSettleIAP is not configured. Call configure() first."
        case .invalidPublishableKey:
            return "Invalid publishable key. Check your ZeroSettle dashboard."
        case .productNotFound(let productId):
            return "Product not found: \(productId)"
        case .checkoutFailed(let reason):
            switch reason {
            case .productNotFound:
                return "Checkout failed: product not found."
            case .merchantNotOnboarded:
                return "Checkout failed: merchant has not completed payment setup."
            case .stripeError(_, let message):
                return "Payment error: \(message)"
            case .serverError(let statusCode, let message):
                return "Checkout failed: server error (\(statusCode))\(message.map { " — \($0)" } ?? "")"
            case .networkUnavailable:
                return "Checkout failed: no network connection."
            case .other(let message):
                return "Checkout failed: \(message)"
            }
        case .transactionVerificationFailed(let message):
            return "Transaction verification failed: \(message)"
        case .apiError(let detail):
            return detail.errorDescription
        case .invalidCallbackURL:
            return "Invalid checkout callback URL."
        case .webCheckoutDisabledForJurisdiction(let jurisdiction):
            return "Web checkout is disabled for the \(jurisdiction.rawValue.uppercased()) jurisdiction. Use StoreKit instead."
        case .userIdRequired(let productId):
            return "A userId is required to purchase \(productId). Subscriptions and non-consumable products require a user identity for entitlement tracking."
        case .restoreEntitlementsFailed(_, let underlyingError):
            return "Failed to restore entitlements: \(underlyingError.localizedDescription)"
        case .cancelled:
            return "Purchase was cancelled."
        case .purchasePending:
            return "Purchase is pending approval."
        case .storeKitVerificationFailed(let underlyingError):
            return "StoreKit verification failed: \(underlyingError.localizedDescription)"
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
        /// Your publishable key from the ZeroSettle dashboard (e.g., "zs_pk_live_abc123").
        /// The key prefix determines sandbox vs live mode (`zs_pk_test_` vs `zs_pk_live_`).
        public let publishableKey: String

        /// Whether to listen for and forward native StoreKit transactions to ZeroSettle.
        /// Set to `false` if you use RevenueCat (which handles StoreKit reporting itself).
        /// Defaults to `true`.
        public let syncStoreKitTransactions: Bool

        public init(
            publishableKey: String,
            syncStoreKitTransactions: Bool = true
        ) {
            self.publishableKey = publishableKey
            self.syncStoreKitTransactions = syncStoreKitTransactions
        }

        internal var backendURL: URL {
            URL(string: "https://api.zerosettle.io/v1")!
        }
    }

    // MARK: - Published State

    /// Whether the SDK has been configured.
    @Published public private(set) var isConfigured: Bool = false

    /// Cached products from the last `fetchProducts()` call.
    @Published public private(set) var products: [ZSProduct] = []

    /// Current entitlements (merged from StoreKit and web checkout sources).
    @Published public private(set) var entitlements: [Entitlement] = []

    /// Whether a web checkout is currently in progress (user is in Safari).
    @Published public private(set) var pendingCheckout: Bool = false

    /// Remote configuration from the backend (populated after `fetchProducts()`).
    /// Contains checkout type settings and optional migration campaign data.
    @Published public private(set) var remoteConfig: RemoteConfig?

    /// The detected jurisdiction based on the user's App Store storefront.
    /// Populated after `fetchProducts()`. Defaults to `.row` if detection fails.
    @Published public private(set) var detectedJurisdiction: Jurisdiction?

    // MARK: - Async Observation

    /// An `AsyncStream` that emits the current entitlements whenever they change.
    ///
    /// Use this for modern async/await observation instead of the delegate:
    /// ```swift
    /// for await entitlements in ZeroSettleIAP.shared.entitlementUpdates {
    ///     updateUI(with: entitlements)
    /// }
    /// ```
    public private(set) lazy var entitlementUpdates: AsyncStream<[Entitlement]> = {
        AsyncStream { [weak self] continuation in
            self?.entitlementContinuation = continuation
        }
    }()

    /// Backing continuation for the entitlements async stream.
    private var entitlementContinuation: AsyncStream<[Entitlement]>.Continuation?

    // MARK: - Computed Properties

    /// The effective checkout type for the detected jurisdiction.
    /// If a jurisdiction override exists, uses that; otherwise falls back to the global default.
    /// Returns `.safari` if remote config hasn't been fetched yet.
    public var checkoutType: CheckoutType {
        guard let config = remoteConfig?.checkout else { return .safari }
        let jurisdiction = detectedJurisdiction ?? .row
        if let override = config.jurisdictions[jurisdiction] {
            return override.sheetType
        }
        return config.sheetType
    }

    /// Whether web checkout is enabled for the detected jurisdiction.
    /// Checks jurisdiction override first, then falls back to the global setting.
    public var isWebCheckoutEnabled: Bool {
        guard let config = remoteConfig?.checkout else { return true }
        let jurisdiction = detectedJurisdiction ?? .row
        if let override = config.jurisdictions[jurisdiction] {
            return override.isEnabled
        }
        return config.isEnabled
    }

    // MARK: - Delegate

    /// Delegate to receive IAP event callbacks.
    public weak var delegate: ZeroSettleIAPDelegate?

    // MARK: - Internal State

    /// Internal accessor for the current configuration.
    internal var currentConfig: Configuration? { config }

    /// The effective base URL, accounting for any debug override.
    internal var effectiveBaseURL: URL? {
        guard let config else { return nil }
        #if DEBUG
        return Self.baseURLOverride ?? config.backendURL
        #else
        return config.backendURL
        #endif
    }

    // MARK: - Private Helpers

    /// Update entitlements and notify all observers (delegate + AsyncStream).
    private func updateEntitlements(_ newEntitlements: [Entitlement]) {
        entitlements = newEntitlements
        entitlementContinuation?.yield(newEntitlements)
        delegate?.zeroSettleIAPEntitlementsDidUpdate(newEntitlements)
    }

    // MARK: - Private State

    private var config: Configuration?
    private var backend: Backend?
    private var checkoutFlow: WebCheckoutFlow?
    private var customerPortalFlow: CustomerPortalFlow?
    private var storeKitManager: StoreKitManager?
    private var pendingTransactionId: String?

    /// Whether `.zeroSettleIAPHandler()` has been installed on a view.
    /// Used to warn developers in DEBUG builds if they forget the modifier.
    internal var handlerInstalled: Bool = false

    // MARK: - Initialization

    private init() {
        Logger.info("ZeroSettleIAP initialized", category: .iap)
    }

    // MARK: - Configuration

    /// Configure the SDK. Must be called before any other methods.
    ///
    /// This method only initializes internal components (backend, checkout flow,
    /// StoreKit listener). It does **not** fetch products, warm up payment sheets,
    /// or restore entitlements — call those methods explicitly after configuration,
    /// or use ``bootstrap(userId:)`` as a convenience that does all three:
    ///
    /// ```swift
    /// // 1. Configure
    /// ZeroSettleIAP.shared.configure(.init(publishableKey: "zs_pk_live_..."))
    ///
    /// // 2. Fetch products (with optional userId for migration eligibility)
    /// let catalog = try await ZeroSettleIAP.shared.fetchProducts(userId: "user_42")
    ///
    /// // 3. (Optional) Warm up payment sheet for instant opens
    /// if let first = catalog.products.first {
    ///     await ZSPaymentSheet.warmUp(productId: first.id, userId: "user_42")
    /// }
    ///
    /// // 4. (Optional) Restore entitlements
    /// let entitlements = try await ZeroSettleIAP.shared.restoreEntitlements(userId: "user_42")
    /// ```
    ///
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
        self.customerPortalFlow = CustomerPortalFlow()

        if config.syncStoreKitTransactions {
            let storeKitManager = StoreKitManager(backend: backend)
            storeKitManager.delegate = self
            storeKitManager.startListening()
            self.storeKitManager = storeKitManager
        }

        isConfigured = true
        Logger.info("ZeroSettleIAP configured", category: .iap)
    }

    // MARK: - Bootstrap

    /// Convenience that fetches products, warms up the payment sheet, and restores entitlements.
    ///
    /// Equivalent to calling ``fetchProducts(userId:)``, ``ZSPaymentSheet/warmUp(productId:userId:)``,
    /// and ``restoreEntitlements(userId:)`` in sequence. Throws if the product fetch or entitlement
    /// restore fails (warm-up failures are non-fatal).
    ///
    /// ```swift
    /// ZeroSettleIAP.shared.configure(.init(publishableKey: "zs_pk_live_..."))
    /// try await ZeroSettleIAP.shared.bootstrap(userId: currentUser.id)
    /// ```
    ///
    /// - Parameter userId: Your app's user identifier for fetching entitlements and migration data
    /// - Returns: A ``ProductCatalog`` containing products and remote configuration
    @discardableResult
    public func bootstrap(userId: String) async throws -> ProductCatalog {
        let catalog = try await fetchProducts(userId: userId)

        // Warm up is non-fatal — just improves first-open latency
        if let first = catalog.products.first {
            await ZSPaymentSheet<EmptyView>.warmUp(productId: first.id, userId: userId)
        }

        try await restoreEntitlements(userId: userId)

        return catalog
    }

    // MARK: - Products

    /// Fetch the product catalog from ZeroSettle with web checkout pricing.
    /// Also reconciles with StoreKit products for native purchasing support.
    /// Results are cached in the `products` and `remoteConfig` published properties.
    ///
    /// - Parameter userId: Optional user ID to check for migration eligibility.
    ///   Pass this to receive migration campaign data in the returned catalog's `config.migration`.
    /// - Returns: A ``ProductCatalog`` containing products and remote configuration
    @discardableResult
    public func fetchProducts(userId: String? = nil) async throws -> ProductCatalog {
        guard let backend else {
            throw ZSError.notConfigured
        }

        do {
            // 1. Fetch from ZeroSettle backend (includes config when userId is provided)
            let catalog = try await backend.fetchProducts(userId: userId)
            var products = catalog.products
            Logger.info("Fetched \(products.count) products from backend", category: .iap)

            // Store remote config for computed properties (checkoutType, isWebCheckoutEnabled)
            if let config = catalog.config {
                remoteConfig = config
                Logger.info("Remote config received: checkoutType=\(config.checkout.sheetType.rawValue), jurisdictions=\(config.checkout.jurisdictions.count), migration=\(config.migration != nil)", category: .iap)
            }

            // Detect jurisdiction from App Store storefront
            await detectJurisdiction()

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
            return ProductCatalog(products: products, config: catalog.config)
        } catch {
            Logger.error("Failed to fetch products: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Purchase

    /// Initiate a web checkout for the given product.
    ///
    /// Opens a Stripe checkout page. The result arrives via the universal link
    /// callback (see ``handleUniversalLink(_:)``).
    ///
    /// - Important: `userId` is **required** for subscriptions and non-consumable products.
    ///   Passing `nil` for these product types throws ``ZSError/userIdRequired(productId:)``.
    ///   Consumable products may omit `userId`.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: Your app's user identifier. Required for subscriptions and non-consumables.
    ///     Must match your RevenueCat app user ID if using RC.
    public func purchase(productId: String, userId: String? = nil) async throws {
        guard let checkoutFlow else {
            throw ZSError.notConfigured
        }

        // Warn if the universal link handler isn't installed
        #if DEBUG
        if !handlerInstalled {
            Logger.error("⚠️ .zeroSettleIAPHandler() is not installed on any view. Universal link callbacks from Safari checkout will not be received. Add .zeroSettleIAPHandler() to your root view.", category: .iap)
        }
        #endif

        // Subscriptions and non-consumables require a userId for entitlement tracking
        if userId == nil,
           let product = products.first(where: { $0.id == productId }),
           product.type == .autoRenewableSubscription || product.type == .nonRenewingSubscription || product.type == .nonConsumable {
            #if DEBUG
            assertionFailure("userId is required for \(product.type.rawValue) products. Pass a userId to purchase() or purchaseViaStoreKit().")
            #endif
            throw ZSError.userIdRequired(productId: productId)
        }

        // Check if web checkout is enabled for the detected jurisdiction
        if !isWebCheckoutEnabled {
            let jurisdiction = detectedJurisdiction ?? .row
            throw ZSError.webCheckoutDisabledForJurisdiction(jurisdiction)
        }

        // Update StoreKit manager with user ID for future sync operations
        if let userId {
            storeKitManager?.setUserId(userId)
        }

        // Signal checkout started BEFORE opening browser
        pendingCheckout = true
        delegate?.zeroSettleIAPCheckoutDidBegin(productId: productId)

        do {
            let session = try await checkoutFlow.beginCheckout(
                productId: productId,
                userId: userId
            )

            pendingTransactionId = session.transactionId

            Logger.info("Checkout browser dismissed for \(productId), transaction: \(session.transactionId ?? "none")", category: .iap)

            // If callback already processed (universal link worked), we're done
            guard pendingCheckout else {
                Logger.debug("Callback already processed via universal link", category: .iap)
                return
            }

            // Universal link didn't fire — poll the backend for transaction status
            guard let transactionId = session.transactionId, let _ = backend else {
                // No transaction ID or backend — treat as cancelled
                pendingCheckout = false
                pendingTransactionId = nil
                delegate?.zeroSettleIAPCheckoutDidCancel(productId: productId)
                return
            }

            await resolveTransactionStatus(
                transactionId: transactionId,
                productId: productId
            )
        } catch {
            pendingCheckout = false
            pendingTransactionId = nil
            Logger.error("Checkout failed for \(productId): \(error)", category: .iap)
            delegate?.zeroSettleIAPCheckoutDidFail(productId: productId, error: error)

            let reason: CheckoutFailure
            if let httpError = error as? HTTPError {
                switch httpError {
                case .httpError(let statusCode, let body):
                    let parsed = Self.parseServerBody(body)
                    switch parsed.code {
                    case "product_not_found":
                        reason = .productNotFound
                    case "merchant_not_onboarded":
                        reason = .merchantNotOnboarded
                    default:
                        if let code = parsed.code, code.hasPrefix("stripe_") {
                            reason = .stripeError(code: parsed.code, message: parsed.message ?? "Payment failed")
                        } else {
                            reason = .serverError(statusCode: statusCode, message: parsed.message)
                        }
                    }
                case .networkError:
                    reason = .networkUnavailable
                default:
                    reason = .other(error.localizedDescription)
                }
            } else if let iapError = error as? ZSError {
                throw iapError
            } else {
                reason = .other(error.localizedDescription)
            }
            throw ZSError.checkoutFailed(reason: reason)
        }
    }

    /// Purchase a product via native StoreKit 2.
    ///
    /// Use this for products synced to App Store Connect where ``ZSProduct/storeKitAvailable`` is `true`.
    ///
    /// - Important: `userId` is **required** for subscriptions and non-consumable products.
    ///   Passing `nil` for these product types throws ``ZSError/userIdRequired(productId:)``.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: Your app's user identifier. Required for subscriptions and non-consumables.
    /// - Returns: The verified StoreKit transaction
    public func purchaseViaStoreKit(productId: String, userId: String? = nil) async throws -> StoreKit.Transaction {
        guard let storeKitManager else {
            throw ZSError.notConfigured
        }

        guard let product = products.first(where: { $0.id == productId }) else {
            throw ZSError.productNotFound(productId)
        }

        // Subscriptions and non-consumables require a userId for entitlement tracking
        if userId == nil,
           product.type == .autoRenewableSubscription || product.type == .nonRenewingSubscription || product.type == .nonConsumable {
            #if DEBUG
            assertionFailure("userId is required for \(product.type.rawValue) products. Pass a userId to purchase() or purchaseViaStoreKit().")
            #endif
            throw ZSError.userIdRequired(productId: productId)
        }

        guard let skProduct = product._storeKitProduct else {
            throw StoreKitPurchaseError.productNotFound(productId)
        }

        if let userId {
            storeKitManager.setUserId(userId)
        }
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
            throw ZSError.notConfigured
        }

        do {
            try await backend.trackMigrationConversion(userId: userId)
            Logger.info("Migration conversion tracked for user: \(userId)", category: .iap)
        } catch {
            Logger.error("Failed to track migration conversion: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Customer Portal

    /// Open the Stripe customer portal for subscription management.
    /// Creates a portal session via the backend, presents it in SFSafariViewController,
    /// and automatically refreshes entitlements when the user dismisses.
    ///
    /// - Parameter userId: Your app's user identifier
    public func openCustomerPortal(userId: String) async throws {
        guard let backend, let customerPortalFlow else {
            throw ZSError.notConfigured
        }

        do {
            let session = try await backend.createCustomerPortalSession(userId: userId)
            Logger.info("Customer portal session created", category: .iap)

            delegate?.zeroSettleIAPCustomerPortalDidOpen(userId: userId)
            await customerPortalFlow.presentPortal(url: session.portalUrl)
            delegate?.zeroSettleIAPCustomerPortalDidClose(userId: userId)

            Logger.info("Customer portal dismissed, refreshing entitlements", category: .iap)
            _ = try? await restoreEntitlements(userId: userId)
        } catch {
            Logger.error("Customer portal failed: \(error)", category: .iap)
            delegate?.zeroSettleIAPCustomerPortalDidFail(userId: userId, error: error)
            throw Backend.wrapError(error)
        }
    }

    /// Smart subscription management that routes to the appropriate UI based on entitlement sources.
    ///
    /// - Web checkout entitlements (or no entitlements) → Opens Stripe customer portal
    /// - StoreKit-only entitlements → Opens Apple's native subscription management
    /// - Both sources → Opens Stripe customer portal (more comprehensive)
    ///
    /// - Parameter userId: Your app's user identifier
    public func showManageSubscription(userId: String) async throws {
        let hasWebEntitlements = entitlements.contains { $0.source == .webCheckout }
        let hasStoreKitEntitlements = entitlements.contains { $0.source == .storeKit }

        if hasStoreKitEntitlements && !hasWebEntitlements {
            // StoreKit-only: use Apple's native management
            Logger.info("Showing Apple subscription management (StoreKit-only entitlements)", category: .iap)
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                Logger.error("No window scene available for subscription management", category: .iap)
                return
            }
            try await AppStore.showManageSubscriptions(in: windowScene)
            _ = try? await restoreEntitlements(userId: userId)
        } else {
            // Web checkout, both sources, or no entitlements: use Stripe portal
            Logger.info("Opening Stripe customer portal (web/mixed/no entitlements)", category: .iap)
            try await openCustomerPortal(userId: userId)
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
    ///
    /// Call this on app launch to recover from missed deeplinks or to sync state.
    /// Merges entitlements from both StoreKit (local) and web checkout (backend).
    ///
    /// If the backend call fails, partial (StoreKit-only) entitlements are still
    /// published to ``entitlements`` before the error is thrown.
    ///
    /// - Parameter userId: Your app's user identifier (required)
    /// - Returns: The merged entitlements from all sources
    @discardableResult
    public func restoreEntitlements(userId: String) async throws -> [Entitlement] {
        Logger.info("[restoreEntitlements] Called with userId=\"\(userId)\"", category: .iap)

        guard let backend else {
            Logger.error("[restoreEntitlements] SDK not configured, throwing notConfigured", category: .iap)
            throw ZSError.notConfigured
        }

        // Update StoreKit manager with user ID
        storeKitManager?.setUserId(userId)

        var allEntitlements: [Entitlement] = []

        // Fetch StoreKit entitlements first (these always succeed locally)
        if let storeKitManager {
            let storeKitEntitlements = await storeKitManager.getCurrentEntitlements()
            allEntitlements.append(contentsOf: storeKitEntitlements)
            Logger.info("[restoreEntitlements] Restored \(storeKitEntitlements.count) StoreKit entitlements for userId=\"\(userId)\": \(storeKitEntitlements.map { "[\($0.productId) active=\($0.isActive)]" })", category: .iap)
        } else {
            Logger.info("[restoreEntitlements] No StoreKit manager configured, skipping StoreKit entitlements", category: .iap)
        }

        // Fetch web checkout entitlements from ZeroSettle backend
        do {
            Logger.info("[restoreEntitlements] Fetching web entitlements from backend for userId=\"\(userId)\"...", category: .iap)
            let webEntitlements = try await backend.getEntitlements(userId: userId)
            allEntitlements.append(contentsOf: webEntitlements)
            Logger.info("[restoreEntitlements] Restored \(webEntitlements.count) web entitlements for userId=\"\(userId)\": \(webEntitlements.map { "[\($0.productId) active=\($0.isActive)]" })", category: .iap)
        } catch {
            Logger.error("[restoreEntitlements] Failed to fetch web entitlements for userId=\"\(userId)\": \(error)", category: .iap)
            // Update with partial (StoreKit-only) entitlements before throwing
            updateEntitlements(allEntitlements)
            throw ZSError.restoreEntitlementsFailed(
                partialEntitlements: allEntitlements,
                underlyingError: error
            )
        }

        updateEntitlements(allEntitlements)
        Logger.info("[restoreEntitlements] Final entitlements for userId=\"\(userId)\": \(allEntitlements.map { "[\($0.productId) source=\($0.source) active=\($0.isActive)]" })", category: .iap)

        return allEntitlements
    }

    // MARK: - Error Helpers

    /// Parsed error body from an HTTP response for checkout failure classification.
    private struct ServerErrorBody {
        let code: String?
        let message: String?
    }

    /// Parse JSON error body from an HTTP response for checkout failure classification.
    private static func parseServerBody(_ body: Data?) -> ServerErrorBody {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ServerErrorBody(code: nil, message: nil)
        }
        let code = json["code"] as? String
        let message = json["error"] as? String ?? json["message"] as? String ?? json["detail"] as? String
        return ServerErrorBody(code: code, message: message)
    }

    // MARK: - Private

    /// Detect the user's jurisdiction from the App Store storefront.
    /// Falls back to `.row` (most restrictive) if storefront is unavailable
    /// (e.g., user not signed into App Store on Simulator).
    private func detectJurisdiction() async {
        if #available(iOS 16.0, *) {
            if let storefront = await Storefront.current {
                let jurisdiction = Jurisdiction.from(storefrontCountryCode: storefront.countryCode)
                detectedJurisdiction = jurisdiction
                Logger.info("Detected jurisdiction: \(jurisdiction.rawValue) (storefront: \(storefront.countryCode))", category: .iap)
                return
            }
        }
        // Fallback: no storefront available → default to ROW (most restrictive)
        detectedJurisdiction = .row
        Logger.info("Storefront unavailable, defaulting to ROW jurisdiction", category: .iap)
    }

    /// Poll the backend to determine whether a checkout completed or was abandoned.
    /// Called when SFSafariViewController is dismissed without a universal link callback.
    private func resolveTransactionStatus(transactionId: String, productId: String) async {
        guard let backend else { return }

        // Brief delay to allow Stripe webhook to process
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        // If universal link callback arrived during the delay, we're done
        guard pendingCheckout else {
            Logger.debug("Callback arrived during polling delay", category: .iap)
            return
        }

        // Poll with retries — payments (especially Apple Pay) can stay in
        // "processing" for several seconds before transitioning to "completed".
        let maxAttempts = 6
        let pollInterval: UInt64 = 2_000_000_000 // 2s

        for attempt in 1...maxAttempts {
            do {
                let transaction = try await backend.getTransaction(transactionId: transactionId)

                if transaction.status == .completed {
                    Logger.info("Transaction \(transactionId) confirmed completed via polling (attempt \(attempt))", category: .iap)
                    let callback = CheckoutCallback(
                        transactionId: transactionId,
                        productId: productId,
                        success: true
                    )
                    await processCheckoutCallback(callback)
                    return
                } else if transaction.status == .processing {
                    Logger.info("Transaction \(transactionId) still processing (attempt \(attempt)/\(maxAttempts))", category: .iap)
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: pollInterval)
                        guard pendingCheckout else {
                            Logger.debug("Callback arrived during processing poll", category: .iap)
                            return
                        }
                        continue
                    }
                    // Final attempt still processing — treat as success and let
                    // the app resolve via entitlement check later
                    Logger.info("Transaction \(transactionId) still processing after \(maxAttempts) attempts — treating as completed", category: .iap)
                    let callback = CheckoutCallback(
                        transactionId: transactionId,
                        productId: productId,
                        success: true
                    )
                    await processCheckoutCallback(callback)
                    return
                } else {
                    // pending (no payment started), failed, etc. — user dismissed without completing
                    Logger.info("Transaction \(transactionId) status \(transaction.status.rawValue) — treating as cancelled", category: .iap)
                    pendingCheckout = false
                    pendingTransactionId = nil
                    delegate?.zeroSettleIAPCheckoutDidCancel(productId: productId)
                    return
                }
            } catch {
                Logger.error("Failed to poll transaction status (attempt \(attempt)): \(error)", category: .iap)
                if attempt == maxAttempts {
                    pendingCheckout = false
                    pendingTransactionId = nil
                    delegate?.zeroSettleIAPCheckoutDidCancel(productId: productId)
                    return
                }
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

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

            guard transaction.status == .completed || transaction.status == .processing else {
                let error = ZSError.transactionVerificationFailed(
                    "Transaction status: \(transaction.status.rawValue)"
                )
                delegate?.zeroSettleIAPCheckoutDidFail(productId: callback.productId, error: error)
                pendingTransactionId = nil
                return
            }

            Logger.info("Checkout \(transaction.status == .processing ? "processing" : "completed"): \(transaction.id) for \(transaction.productId)", category: .iap)
            delegate?.zeroSettleIAPCheckoutDidComplete(transaction: transaction)

            // Fetch fresh entitlements from backend to get proper expiry dates
            // This ensures subscription expiresAt is populated correctly from the server
            if let userId = storeKitManager?.currentUserId {
                do {
                    let freshEntitlements = try await backend.getEntitlements(userId: userId)
                    // Merge: keep StoreKit entitlements, add/replace web entitlements
                    let storeKitEnts = entitlements.filter { $0.source == .storeKit }
                    updateEntitlements(storeKitEnts + freshEntitlements)
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
                    var updated = entitlements
                    updated.append(entitlement)
                    updateEntitlements(updated)
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
                var updated = entitlements
                updated.append(entitlement)
                updateEntitlements(updated)
            }

        } catch {
            Logger.error("Transaction verification failed: \(error)", category: .iap)
            delegate?.zeroSettleIAPCheckoutDidFail(
                productId: callback.productId,
                error: ZSError.transactionVerificationFailed(error.localizedDescription)
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

    nonisolated func storeKitEntitlementsDidChange(_ storeKitEntitlements: [Entitlement]) {
        Task { @MainActor in
            // Merge: keep web entitlements, replace StoreKit entitlements
            let webEntitlements = self.entitlements.filter { $0.source == .webCheckout }
            updateEntitlements(webEntitlements + storeKitEntitlements)
        }
    }
}
