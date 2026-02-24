//
//  ZeroSettle.swift
//  ZeroSettleKit
//
//  Main entry point for the ZeroSettle IAP SDK.
//  Provides web checkout for in-app purchases via Stripe.
//

import Foundation
import StoreKit
import SwiftUI

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
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
    /// The original error that was thrown by the networking layer, if any.
    public let underlyingError: (any Error)?

    public var errorDescription: String? {
        if let serverMessage {
            return serverMessage
        }
        if let statusCode {
            return "Server error (\(statusCode))"
        }
        return underlyingError?.localizedDescription ?? "Unknown API error"
    }
}

/// Classifies checkout failures into actionable categories.
///
/// Use this to distinguish between card declines, server errors, and network issues
/// when handling ``ZeroSettleError/checkoutFailed(reason:)``.
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
/// All public methods throw `ZeroSettleError`. Match on specific cases to handle
/// different failure modes:
/// ```swift
/// do {
///     try await ZeroSettle.shared.purchase(productId: "premium", userId: "user_42")
/// } catch let error as ZeroSettleError {
///     switch error {
///     case .notConfigured: // SDK not set up
///     case .cancelled: // User cancelled
///     case .checkoutFailed(let reason): // Payment failure
///     case .apiError(let detail): // Network/server error
///     default: break
///     }
/// }
/// ```
public enum ZeroSettleError: Error, LocalizedError {
    /// The SDK has not been configured. Call ``ZeroSettle/configure(_:)`` first.
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
            return "ZeroSettle is not configured. Call configure() first."
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

// MARK: - Funnel Event Types

/// Funnel analytics event types for paywall and checkout tracking.
public enum FunnelEventType: String, Sendable {
    case paywallViewed = "paywall_viewed"
    case checkoutStarted = "checkout_started"
    case checkoutAbandoned = "checkout_abandoned"
}

// MARK: - ZeroSettle IAP

/// Main entry point for the ZeroSettle IAP SDK.
/// Handles web checkout, entitlement management, and StoreKit transaction syncing.
@MainActor
public final class ZeroSettle: ObservableObject {

    // MARK: - Singleton

    public static let shared = ZeroSettle()

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

        /// Apple Pay merchant identifier for native pay checkout.
        /// Required when using the `NativePay` package trait.
        /// If nil, the SDK uses the merchant ID from the backend config (managed mode default).
        public let appleMerchantId: String?

        public init(
            publishableKey: String,
            syncStoreKitTransactions: Bool = true,
            appleMerchantId: String? = nil
        ) {
            self.publishableKey = publishableKey
            self.syncStoreKitTransactions = syncStoreKitTransactions
            self.appleMerchantId = appleMerchantId
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
    ///
    /// **SwiftUI**: Observe via `@ObservedObject` — the property is `@Published` and drives
    /// view updates automatically.
    ///
    /// For UIKit or structured concurrency alternatives, see ``ZeroSettleDelegate`` and
    /// ``entitlementUpdates``.
    @Published public private(set) var entitlements: [Entitlement] = []

    /// Whether a web checkout is currently in progress (user is in Safari).
    @Published public private(set) var pendingCheckout: Bool = false

    /// Remote configuration from the backend (populated after `fetchProducts()`).
    /// Contains checkout type settings and optional migration campaign data.
    @Published public private(set) var remoteConfig: RemoteConfig?

    /// The detected jurisdiction based on the user's App Store storefront.
    /// Populated after `fetchProducts()`. Defaults to `.row` if detection fails.
    @Published public private(set) var detectedJurisdiction: Jurisdiction?

    /// Whether ``bootstrap(userId:)`` has completed.
    @Published public private(set) var isBootstrapped: Bool = false

    /// Cached cancel flow configuration from the backend.
    /// Populated during ``bootstrap(userId:)`` so it's immediately available
    /// for building custom cancel flow UI without an extra network call.
    @Published public private(set) var cancelFlowConfig: CancelFlow.Config?

    /// Migration manager for the StoreKit → web checkout migration flow.
    /// Access via ``migrationManager(for:)`` to guarantee a single shared instance.
    /// Starts in `.loading` and transitions after bootstrap completes.
    @Published public private(set) var migrationManager: ZSMigrationManager?

    // MARK: - Async Observation

    /// An `AsyncStream` that emits the current entitlements whenever they change.
    ///
    /// Use this for modern async/await observation instead of the delegate:
    /// ```swift
    /// for await entitlements in ZeroSettle.shared.entitlementUpdates {
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
    /// Returns `.webView` if remote config hasn't been fetched yet.
    public var checkoutType: CheckoutType {
        guard let config = remoteConfig?.checkout else { return .webView }
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

    /// Resolve the Apple Pay merchant ID: local override > backend default > nil.
    private var resolvedMerchantId: String? {
        if let local = config?.appleMerchantId, !local.isEmpty {
            return local
        }
        if let remote = remoteConfig?.checkout.appleMerchantId, !remote.isEmpty {
            return remote
        }
        return nil
    }

    // MARK: - Delegate

    /// Delegate to receive IAP event callbacks.
    public weak var delegate: ZeroSettleDelegate?

    // MARK: - Internal State

    /// Internal accessor for the current configuration.
    internal var currentConfig: Configuration? { config }

    /// Whether the SDK is running in sandbox mode (test publishable key).
    internal var isSandbox: Bool {
        config?.publishableKey.hasPrefix("zs_pk_test_") ?? false
    }

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

    /// Throws ``ZeroSettleError/userIdRequired(productId:)`` when a `userId` is needed but absent.
    private func validateUserIdIfRequired(for product: ZSProduct, userId: String?) throws {
        guard userId == nil else { return }
        guard product.type == .autoRenewableSubscription
           || product.type == .nonRenewingSubscription
           || product.type == .nonConsumable else { return }
        #if DEBUG
        assertionFailure("userId is required for \(product.type.rawValue) products. Pass a userId to purchase() or purchaseViaStoreKit().")
        #endif
        throw ZeroSettleError.userIdRequired(productId: product.id)
    }

    /// Update entitlements and notify all observers (delegate + AsyncStream).
    private func updateEntitlements(_ newEntitlements: [Entitlement]) {
        entitlements = newEntitlements
        entitlementContinuation?.yield(newEntitlements)
        delegate?.zeroSettleEntitlementsDidUpdate(newEntitlements)
    }

    // MARK: - Private State

    private var config: Configuration?
    private var backend: Backend?
    private var checkoutFlow: WebCheckoutFlow?
    private var customerPortalFlow: CustomerPortalFlow?
    private var storeKitManager: StoreKitManager?

    #if NativePay
    private var nativePayFlow: NativePay.Flow?
    #endif

    /// Whether `.zeroSettleHandler()` has been installed on a view.
    /// Used to warn developers in DEBUG builds if they forget the modifier.
    internal var handlerInstalled: Bool = false

    // MARK: - Initialization

    private init() {
        ZSLogger.info("ZeroSettle initialized", category: .iap)
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
    /// ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_live_..."))
    ///
    /// // 2. Fetch products (with optional userId for migration eligibility)
    /// let catalog = try await ZeroSettle.shared.fetchProducts(userId: "user_42")
    ///
    /// // 3. (Optional) Restore entitlements
    /// let entitlements = try await ZeroSettle.shared.restoreEntitlements(userId: "user_42")
    /// ```
    ///
    /// - Parameter config: The IAP configuration with your publishable key
    public func configure(_ config: Configuration) {
        // Clear cached checkout URLs from the previous environment to prevent
        // stale sandbox PIs being served after switching to live (or vice versa).
        CheckoutCache.shared.clearAll()

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

        #if NativePay
        self.nativePayFlow = NativePay.Flow(backend: backend)
        #endif

        if config.syncStoreKitTransactions {
            let storeKitManager = StoreKitManager(backend: backend)
            storeKitManager.delegate = self
            storeKitManager.startListening()
            self.storeKitManager = storeKitManager
        }

        isConfigured = true

        let mode = config.publishableKey.hasPrefix("zs_pk_test_") ? "sandbox" : "live"
        let syncStatus = config.syncStoreKitTransactions ? "enabled" : "disabled"
        let merchantStatus = config.appleMerchantId ?? "none (webview fallback)"
        let nativePayStatus: String
        #if NativePay
        nativePayStatus = "compiled in"
        #else
        nativePayStatus = "not compiled (add NativePay trait to Package.swift)"
        #endif
        ZSLogger.info("ZeroSettle configured: mode=\(mode), storeKitSync=\(syncStatus), appleMerchantId=\(merchantStatus), nativePay=\(nativePayStatus)", category: .iap)
    }

    // MARK: - Bootstrap

    /// Convenience that fetches products and restores entitlements.
    ///
    /// Equivalent to calling ``fetchProducts(userId:)`` and ``restoreEntitlements(userId:)``
    /// in sequence. Throws if the product fetch or entitlement restore fails.
    ///
    /// To preload payment sheets, use the `preload` parameter on `.checkoutSheet()`:
    /// ```swift
    /// ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_live_..."))
    /// try await ZeroSettle.shared.bootstrap(userId: currentUser.id)
    /// ```
    ///
    /// - Parameter userId: Your app's user identifier for fetching entitlements and migration data
    /// - Returns: A ``ProductCatalog`` containing products and remote configuration
    @discardableResult
    public func bootstrap(userId: String) async throws -> ProductCatalog {
        // 1. Sync StoreKit transactions to the backend so the Identity and
        //    Entitlement records exist before we check migration eligibility.
        if let storeKitManager {
            storeKitManager.setUserId(userId)
            await storeKitManager.syncCurrentTransactions(userId: userId)
        }

        // 2. Fetch products, cancel flow config, and restore entitlements in parallel.
        //    Products can now check migration eligibility because the Identity
        //    was created by the sync above.
        async let catalogTask = fetchProducts(userId: userId)
        async let cancelFlowTask: Void = loadCancelFlowConfig(userId: userId)
        async let _entitlementsTask: Void = {
            try await self.restoreEntitlements(userId: userId)
        }()

        let catalog = try await catalogTask
        await cancelFlowTask
        _ = try await _entitlementsTask

        isBootstrapped = true

        // 4. Ensure migration manager exists. If the view already created one
        //    (via migrationManager(for:)), reuse it — Combine will re-evaluate
        //    now that isBootstrapped is true. Otherwise create one with full data.
        _ = migrationManager(for: userId)

        return catalog
    }

    // MARK: - Migration Manager

    /// Returns the shared migration manager, creating one if it doesn't exist yet.
    ///
    /// Both ``MigrationTipView`` and ``bootstrap(userId:)`` call this to guarantee
    /// a single shared instance. The manager starts in `.loading` and transitions
    /// to `.eligible` or `.ineligible` once bootstrap completes (via Combine).
    ///
    /// - Parameter userId: Your app's user identifier
    /// - Returns: The shared ``ZSMigrationManager``
    @discardableResult
    public func migrationManager(for userId: String) -> ZSMigrationManager {
        if let existing = migrationManager { return existing }
        let manager = ZSMigrationManager(userId: userId)
        migrationManager = manager
        return manager
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
            throw ZeroSettleError.notConfigured
        }

        do {
            // 1. Fetch from ZeroSettle backend (includes config when userId is provided)
            let catalog = try await backend.fetchProducts(userId: userId)
            var products = catalog.products
            ZSLogger.info("Fetched \(products.count) products from backend", category: .iap)

            // Store remote config for computed properties (checkoutType, isWebCheckoutEnabled)
            if let config = catalog.config {
                remoteConfig = config
                ZSLogger.info("Remote config received: checkoutType=\(config.checkout.sheetType.rawValue), jurisdictions=\(config.checkout.jurisdictions.count), migration=\(config.migration != nil)", category: .iap)
            }

            // Detect jurisdiction from App Store storefront
            await detectJurisdiction()

            // 2. Try to fetch ALL products from StoreKit (let StoreKit tell us what exists)
            let allProductIds = products.map { $0.id }

            // 3. Fetch StoreKit products (if StoreKit sync enabled)
            if let storeKitManager, !allProductIds.isEmpty {
                let skProducts = await storeKitManager.fetchProducts(for: allProductIds)

                // 4. Attach StoreKit products to our ZSProduct models
                // Products that exist in StoreKit get _storeKitProduct populated
                // Products that don't exist remain web-only
                for i in products.indices {
                    if let skProduct = skProducts[products[i].id] {
                        products[i]._storeKitProduct = skProduct
                    }
                }

                let matched = products.filter { $0.storeKitAvailable }.count
                ZSLogger.info("Reconciled \(matched)/\(products.count) products with StoreKit", category: .iap)
            }

            self.products = products
            return ProductCatalog(products: products, config: catalog.config)
        } catch {
            ZSLogger.error("Failed to fetch products: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Purchase

    /// Initiate a web checkout for the given product.
    ///
    /// Opens a Stripe checkout page in the configured checkout type (Safari, SFSafariViewController,
    /// or WebView) and returns the verified transaction on success. For Safari/SafariVC paths, the
    /// result may arrive via the universal link callback or by polling the backend after the browser
    /// is dismissed.
    ///
    /// - Important: `userId` is **required** for subscriptions and non-consumable products.
    ///   Passing `nil` for these product types throws ``ZeroSettleError/userIdRequired(productId:)``.
    ///   Consumable products may omit `userId`.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: Your app's user identifier. Required for subscriptions and non-consumables.
    ///     Must match your RevenueCat app user ID if using RC.
    /// - Returns: The verified ``CheckoutTransaction`` on success
    @discardableResult
    public func purchase(productId: String, userId: String? = nil) async throws -> CheckoutTransaction {
        guard let checkoutFlow, let backend else {
            throw ZeroSettleError.notConfigured
        }

        // Warn if the universal link handler isn't installed
        #if DEBUG
        if !handlerInstalled {
            ZSLogger.error("⚠️ .zeroSettleHandler() is not installed on any view. Universal link callbacks from Safari checkout will not be received. Add .zeroSettleHandler() to your root view.", category: .iap)
        }
        #endif

        // Subscriptions and non-consumables require a userId for entitlement tracking
        if let product = products.first(where: { $0.id == productId }) {
            try validateUserIdIfRequired(for: product, userId: userId)
        }

        // Log the effective checkout routing decision
        let effectiveJurisdiction = detectedJurisdiction ?? .row
        let effectiveType = checkoutType
        ZSLogger.info("Checkout routing: product=\(productId), jurisdiction=\(effectiveJurisdiction.rawValue), checkoutType=\(effectiveType.rawValue), webCheckoutEnabled=\(isWebCheckoutEnabled)", category: .iap)

        // Check if web checkout is enabled for the detected jurisdiction
        if !isWebCheckoutEnabled {
            ZSLogger.error("Web checkout disabled for \(effectiveJurisdiction.rawValue) jurisdiction. The SDK will throw webCheckoutDisabledForJurisdiction. Configure this in your ZeroSettle dashboard under Checkout Configuration.", category: .iap)
            throw ZeroSettleError.webCheckoutDisabledForJurisdiction(effectiveJurisdiction)
        }

        // Update StoreKit manager with user ID for future sync operations
        if let userId {
            storeKitManager?.setUserId(userId)
        }

        // Signal checkout started BEFORE opening browser
        pendingCheckout = true
        delegate?.zeroSettleCheckoutDidBegin(productId: productId)

        // Native Pay: use STPApplePayContext when trait is enabled + device supports it
        #if NativePay
        if checkoutType == .nativePay, let nativePayFlow {
            if let merchantId = resolvedMerchantId, nativePayFlow.canMakePayments() {
                ZSLogger.info("Starting native Apple Pay checkout for \(productId)", category: .iap)
                do {
                    let result = try await nativePayFlow.pay(
                        productId: productId,
                        userId: userId,
                        merchantId: merchantId
                    )
                    pendingCheckout = false
                    switch result {
                    case .success(let transaction):
                        delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                        await refreshEntitlementsAfterCheckout(transaction: transaction)
                        return transaction
                    case .cancelled:
                        delegate?.zeroSettleCheckoutDidCancel(productId: productId)
                        throw ZeroSettleError.cancelled
                    }
                } catch let error as ZeroSettleError {
                    pendingCheckout = false
                    throw error
                } catch {
                    pendingCheckout = false
                    ZSLogger.error("Native Apple Pay failed for \(productId): \(error)", category: .iap)
                    delegate?.zeroSettleCheckoutDidFail(productId: productId, error: error)
                    throw ZeroSettleError.checkoutFailed(reason: .other(error.localizedDescription))
                }
            } else {
                // Log the specific reason for fallback
                if resolvedMerchantId == nil {
                    ZSLogger.info("Native Pay fallback → webview: no appleMerchantId configured. Pass appleMerchantId in Configuration or configure apple_merchant_id on the backend.", category: .iap)
                } else if !nativePayFlow.canMakePayments() {
                    ZSLogger.info("Native Pay fallback → webview: Apple Pay is not available on this device (no cards configured or device doesn't support Apple Pay).", category: .iap)
                }
            }
        }
        #endif

        do {
            let session = try await checkoutFlow.beginCheckout(
                productId: productId,
                userId: userId
            )

            ZSLogger.info("Checkout browser dismissed for \(productId), transaction: \(session.transactionId ?? "none")", category: .iap)

            // Brief yield to allow any pending universal link callback Task to process.
            // The foreground notification fires before scene(_:continue:), so
            // processCheckoutCallback may still be queued when we reach this point.
            try? await Task.sleep(nanoseconds: 500_000_000)

            // If the universal link callback already fired, pendingCheckout is false
            // and processCheckoutCallback already handled delegate/entitlements.
            // Just fetch the transaction to return it.
            guard pendingCheckout else {
                ZSLogger.debug("Callback already processed via universal link", category: .iap)
                if let transactionId = session.transactionId {
                    let transaction = try await backend.getTransaction(transactionId: transactionId)
                    return transaction
                }
                throw ZeroSettleError.cancelled
            }

            // Universal link didn't fire — verify via polling
            guard let transactionId = session.transactionId else {
                pendingCheckout = false

                delegate?.zeroSettleCheckoutDidCancel(productId: productId)
                throw ZeroSettleError.cancelled
            }

            do {
                let transaction = try await backend.verifyTransaction(transactionId: transactionId)

                // If the universal link callback already processed this checkout
                // (during the polling delay), skip the delegate call to avoid duplicates.
                guard pendingCheckout else {
                    ZSLogger.debug("Transaction \(transactionId) verified, but callback already handled it", category: .iap)
                    return transaction
                }
                pendingCheckout = false

                ZSLogger.info("Transaction \(transactionId) verified via polling", category: .iap)
                delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                await refreshEntitlementsAfterCheckout(transaction: transaction)
                return transaction
            } catch let sheetError as PaymentSheetError {
                pendingCheckout = false

                switch sheetError {
                case .cancelled:
                    delegate?.zeroSettleCheckoutDidCancel(productId: productId)
                    throw ZeroSettleError.cancelled
                case .verificationFailed(let message):
                    delegate?.zeroSettleCheckoutDidFail(productId: productId, error: sheetError)
                    throw ZeroSettleError.transactionVerificationFailed(message)
                default:
                    delegate?.zeroSettleCheckoutDidFail(productId: productId, error: sheetError)
                    throw ZeroSettleError.checkoutFailed(reason: .other(sheetError.localizedDescription ?? "Unknown error"))
                }
            }
        } catch let error as ZeroSettleError {
            pendingCheckout = false
            throw error
        } catch {
            pendingCheckout = false
            ZSLogger.error("Checkout failed for \(productId): \(error)", category: .iap)
            delegate?.zeroSettleCheckoutDidFail(productId: productId, error: error)

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
            } else {
                reason = .other(error.localizedDescription)
            }
            throw ZeroSettleError.checkoutFailed(reason: reason)
        }
    }

    /// Purchase a product via native StoreKit 2.
    ///
    /// Use this for products synced to App Store Connect where ``ZSProduct/storeKitAvailable`` is `true`.
    ///
    /// - Important: `userId` is **required** for subscriptions and non-consumable products.
    ///   Passing `nil` for these product types throws ``ZeroSettleError/userIdRequired(productId:)``.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: Your app's user identifier. Required for subscriptions and non-consumables.
    /// - Returns: The verified StoreKit transaction
    public func purchaseViaStoreKit(productId: String, userId: String? = nil) async throws -> StoreKit.Transaction {
        guard let storeKitManager else {
            throw ZeroSettleError.notConfigured
        }

        guard let product = products.first(where: { $0.id == productId }) else {
            throw ZeroSettleError.productNotFound(productId)
        }

        // Subscriptions and non-consumables require a userId for entitlement tracking
        try validateUserIdIfRequired(for: product, userId: userId)

        guard let skProduct = product._storeKitProduct else {
            throw ZeroSettleError.productNotFound(productId)
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
            throw ZeroSettleError.notConfigured
        }

        do {
            try await backend.trackMigrationConversion(userId: userId)
            ZSLogger.info("Migration conversion tracked for user: \(userId)", category: .iap)
        } catch {
            ZSLogger.error("Failed to track migration conversion: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Funnel Analytics

    /// Fire-and-forget analytics event for paywall and checkout funnel tracking.
    ///
    /// Sends the event to the ZeroSettle backend asynchronously. Errors are
    /// silently logged at debug level and never thrown or surfaced to the caller.
    ///
    /// - Parameters:
    ///   - type: The funnel event type (e.g., `.paywallViewed`, `.checkoutStarted`)
    ///   - productId: The product identifier associated with this event
    ///   - screenName: Optional screen name where the event occurred
    ///   - metadata: Optional key-value pairs for additional context
    public nonisolated static func trackEvent(
        _ type: FunnelEventType,
        productId: String,
        screenName: String? = nil,
        metadata: [String: String]? = nil
    ) {
        Task.detached(priority: .utility) {
            let instance = await ZeroSettle.shared
            guard let backend = await instance.backend else {
                ZSLogger.debug("trackEvent: SDK not configured, dropping event", category: .iap)
                return
            }

            let userId = await instance.storeKitManager?.currentUserId ?? "anonymous"

            do {
                try await backend.trackFunnelEvent(
                    eventType: type.rawValue,
                    userId: userId,
                    productId: productId,
                    screenName: screenName,
                    metadata: metadata
                )
                ZSLogger.debug("trackEvent: \(type.rawValue) sent for product=\(productId)", category: .iap)
            } catch {
                ZSLogger.debug("trackEvent: failed to send \(type.rawValue): \(error)", category: .iap)
            }
        }
    }

    // MARK: - Customer Portal

    /// Direct Stripe portal access only.
    ///
    /// Opens the Stripe customer portal for subscription management.
    /// Creates a portal session via the backend, presents it in SFSafariViewController,
    /// and automatically refreshes entitlements when the user dismisses.
    ///
    /// - Parameter userId: Your app's user identifier
    @available(*, deprecated, message: "Use showManageSubscription(userId:) instead — it auto-routes between Stripe and Apple's native management UI based on entitlement sources.")
    public func openCustomerPortal(userId: String) async throws {
        guard let backend, let customerPortalFlow else {
            throw ZeroSettleError.notConfigured
        }

        do {
            let session = try await backend.createCustomerPortalSession(userId: userId)
            ZSLogger.info("Customer portal session created", category: .iap)

            await customerPortalFlow.presentPortal(url: session.portalUrl)

            ZSLogger.info("Customer portal dismissed, refreshing entitlements", category: .iap)
            _ = try? await restoreEntitlements(userId: userId)
        } catch {
            ZSLogger.error("Customer portal failed: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    /// Recommended default — smart routing for subscription management.
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
            ZSLogger.info("Showing Apple subscription management (StoreKit-only entitlements)", category: .iap)
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                ZSLogger.error("No window scene available for subscription management", category: .iap)
                return
            }
            try await AppStore.showManageSubscriptions(in: windowScene)
            _ = try? await restoreEntitlements(userId: userId)
        } else {
            // Web checkout, both sources, or no entitlements: use Stripe portal
            ZSLogger.info("Opening Stripe customer portal (web/mixed/no entitlements)", category: .iap)
            try await openCustomerPortal(userId: userId)
        }
    }

    // MARK: - Universal Link Handling

    /// Handle a universal link callback from the web checkout.
    /// Call this from your SceneDelegate's `scene(_:continue:)` or
    /// AppDelegate's `application(_:continue:restorationHandler:)`.
    ///
    /// - Parameter url: The universal link URL
    /// - Returns: `true` if the URL was handled by ZeroSettle, `false` otherwise
    @discardableResult
    public func handleUniversalLink(_ url: URL) -> Bool {
        ZSLogger.info("[handleUniversalLink] URL: \(url.absoluteString)", category: .iap)

        guard let checkoutFlow else {
            ZSLogger.error("[handleUniversalLink] checkoutFlow is nil — SDK not configured", category: .iap)
            return false
        }

        ZSLogger.debug("[handleUniversalLink] checkoutFlow exists, parsing callback...", category: .iap)
        guard let callback = checkoutFlow.handleCallback(url: url) else {
            ZSLogger.info("[handleUniversalLink] URL did not match checkout callback pattern", category: .iap)
            return false
        }
        ZSLogger.info("[handleUniversalLink] callback parsed: transaction=\(callback.transactionId), product=\(callback.productId), success=\(callback.success)", category: .iap)

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
        ZSLogger.info("[restoreEntitlements] Called with userId=\"\(userId)\"", category: .iap)

        guard let backend else {
            ZSLogger.error("[restoreEntitlements] SDK not configured, throwing notConfigured", category: .iap)
            throw ZeroSettleError.notConfigured
        }

        // Update StoreKit manager with user ID
        storeKitManager?.setUserId(userId)

        var allEntitlements: [Entitlement] = []

        // Fetch StoreKit entitlements first (these always succeed locally)
        if let storeKitManager {
            let storeKitEntitlements = await storeKitManager.getCurrentEntitlements()
            allEntitlements.append(contentsOf: storeKitEntitlements)
            ZSLogger.info("[restoreEntitlements] Restored \(storeKitEntitlements.count) StoreKit entitlements for userId=\"\(userId)\": \(storeKitEntitlements.map { "[\($0.productId) active=\($0.isActive)]" })", category: .iap)
        } else {
            ZSLogger.info("[restoreEntitlements] No StoreKit manager configured, skipping StoreKit entitlements", category: .iap)
        }

        // Fetch web checkout entitlements from ZeroSettle backend
        do {
            ZSLogger.info("[restoreEntitlements] Fetching web entitlements from backend for userId=\"\(userId)\"...", category: .iap)
            let webEntitlements = try await backend.getEntitlements(userId: userId)
            allEntitlements.append(contentsOf: webEntitlements)
            ZSLogger.info("[restoreEntitlements] Restored \(webEntitlements.count) web entitlements for userId=\"\(userId)\": \(webEntitlements.map { "[\($0.productId) active=\($0.isActive)]" })", category: .iap)
        } catch {
            ZSLogger.error("[restoreEntitlements] Failed to fetch web entitlements for userId=\"\(userId)\": \(error)", category: .iap)
            // Update with partial (StoreKit-only) entitlements before throwing
            updateEntitlements(allEntitlements)
            throw ZeroSettleError.restoreEntitlementsFailed(
                partialEntitlements: allEntitlements,
                underlyingError: error
            )
        }

        updateEntitlements(allEntitlements)
        ZSLogger.info("[restoreEntitlements] Final entitlements for userId=\"\(userId)\": \(allEntitlements.map { "[\($0.productId) source=\($0.source) active=\($0.isActive)]" })", category: .iap)

        return allEntitlements
    }

    // MARK: - Transaction History

    /// Fetch the full transaction history for a user.
    ///
    /// Unlike ``restoreEntitlements(userId:)`` which only returns **active** entitlements,
    /// this method returns all transactions regardless of status — including consumed
    /// consumables, expired subscriptions, refunds, and failed transactions.
    ///
    /// - Parameter userId: Your app's user identifier
    /// - Returns: An array of ``CheckoutTransaction`` ordered by most recent first
    public func fetchTransactionHistory(userId: String) async throws -> [CheckoutTransaction] {
        guard let backend else {
            throw ZeroSettleError.notConfigured
        }

        do {
            let transactions = try await backend.getTransactionHistory(userId: userId)
            ZSLogger.info("Fetched \(transactions.count) transactions for user: \(userId)", category: .iap)
            return transactions
        } catch {
            ZSLogger.error("Failed to fetch transaction history: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Cancel Flow

    /// Present the cancel flow questionnaire for a subscription cancellation.
    ///
    /// Fetches the cancel flow configuration from the backend, then presents a
    /// native SwiftUI sheet with the questionnaire. If the flow is disabled or
    /// has no questions, returns `.cancelled` immediately.
    ///
    /// The response (answers, outcome, funnel data) is automatically submitted
    /// to the backend when the user completes or dismisses the flow.
    ///
    /// - Parameters:
    ///   - productId: The product the user wants to cancel
    ///   - userId: Your app's user identifier
    /// - Returns: The cancel flow outcome (`.cancelled`, `.retained`, `.paused`, or `.dismissed`)
    public func presentCancelFlow(productId: String, userId: String) async -> CancelFlow.Result {
        guard let backend else {
            ZSLogger.error("presentCancelFlow called but SDK not configured", category: .iap)
            return .cancelled
        }

        // Use cached config if available, otherwise fetch
        let config: CancelFlow.Config
        if let cached = cancelFlowConfig {
            config = cached
        } else {
            do {
                config = try await backend.fetchCancelFlow(userId: userId)
                cancelFlowConfig = config
            } catch {
                ZSLogger.error("Failed to fetch cancel flow config: \(error)", category: .iap)
                return .cancelled
            }
        }

        guard config.enabled, !config.questions.isEmpty else {
            ZSLogger.info("Cancel flow disabled or no questions, returning .cancelled", category: .iap)
            return .cancelled
        }

        let presenter = CancelFlowPresenter()
        let result = await presenter.present(
            config: config,
            productId: productId,
            userId: userId,
            backend: backend
        )

        ZSLogger.info("Cancel flow completed with result: \(result)", category: .iap)
        return result
    }

    // MARK: - Headless Cancel Flow API

    /// Fetch the cancel flow configuration without presenting any UI.
    ///
    /// Use this for building custom cancel/pause UI while still using ZeroSettle's
    /// backend configuration. Returns the full config including questions, offer, and pause options.
    ///
    /// After ``bootstrap(userId:)``, the config is also available synchronously via
    /// the ``cancelFlowConfig`` published property.
    ///
    /// - Parameter userId: Optional user ID for A/B experiment targeting
    /// - Returns: The cancel flow ``CancelFlow/Config``
    public func fetchCancelFlowConfig(userId: String? = nil) async throws -> CancelFlow.Config {
        guard let backend else {
            throw ZeroSettleError.notConfigured
        }

        do {
            let config = try await backend.fetchCancelFlow(userId: userId)
            cancelFlowConfig = config
            ZSLogger.info("Fetched cancel flow config: enabled=\(config.enabled), questions=\(config.questions.count), pause=\(config.pause?.enabled ?? false)", category: .iap)
            return config
        } catch {
            ZSLogger.error("Failed to fetch cancel flow config: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    /// Accept the save offer for a subscription, applying the configured discount via Stripe.
    ///
    /// Call this when a user accepts the retention offer in your custom cancel flow UI.
    /// The backend applies the discount coupon from the dashboard config to the user's
    /// Stripe subscription.
    ///
    /// On success, refreshes entitlements automatically.
    ///
    /// - Parameters:
    ///   - productId: The product the user was about to cancel
    ///   - userId: Your app's user identifier
    /// - Returns: A ``CancelFlow/SaveOfferResult`` with details of the applied discount
    public func acceptSaveOffer(productId: String, userId: String) async throws -> CancelFlow.SaveOfferResult {
        guard let backend else {
            throw ZeroSettleError.notConfigured
        }

        do {
            let response = try await backend.acceptSaveOffer(productId: productId, userId: userId)
            ZSLogger.info("Save offer accepted: product=\(productId), message=\(response.message)", category: .iap)

            // Refresh entitlements to reflect the updated subscription
            _ = try? await restoreEntitlements(userId: userId)

            return CancelFlow.SaveOfferResult(
                message: response.message,
                discountPercent: response.discountPercent,
                durationMonths: response.durationMonths
            )
        } catch {
            ZSLogger.error("Failed to accept save offer: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    /// Submit a cancel flow response for analytics tracking.
    ///
    /// Use this when building custom cancel flow UI to report the user's answers and
    /// outcome back to ZeroSettle for funnel analytics in the dashboard.
    ///
    /// This is fire-and-forget — errors are logged but not thrown.
    ///
    /// - Parameter response: The cancel flow response with answers and outcome
    public func submitCancelFlowResponse(_ response: CancelFlow.Response) async {
        guard let backend else {
            ZSLogger.error("submitCancelFlowResponse called but SDK not configured", category: .iap)
            return
        }

        let payload = CancelFlow.ResponsePayload(
            userId: response.userId,
            productId: response.productId,
            outcome: response.outcome.rawValue,
            offerShown: response.offerShown,
            offerAccepted: response.offerAccepted,
            pauseShown: response.pauseShown,
            pauseAccepted: response.pauseAccepted,
            pauseDurationDays: response.pauseDurationDays,
            lastStepSeen: 0,
            answers: response.answers.map {
                CancelFlow.AnswerPayload(
                    questionId: $0.questionId,
                    selectedOptionId: $0.selectedOptionId,
                    freeText: $0.freeText
                )
            }
        )

        do {
            try await backend.submitCancelFlowResponse(payload)
            ZSLogger.debug("Cancel flow response submitted", category: .iap)
        } catch {
            ZSLogger.error("Failed to submit cancel flow response: \(error)", category: .iap)
        }
    }

    /// Pause a subscription for the given product.
    ///
    /// Sends a pause request to the backend with the selected pause option.
    /// On success, refreshes entitlements automatically.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to pause
    ///   - userId: Your app's user identifier
    ///   - pauseOptionId: The ID of the selected ``CancelFlow/PauseOption``
    /// - Returns: The date when the subscription will automatically resume, or `nil` if unspecified
    public func pauseSubscription(productId: String, userId: String, pauseOptionId: Int) async throws -> Date? {
        guard let backend else {
            throw ZeroSettleError.notConfigured
        }

        do {
            let response = try await backend.pauseSubscription(
                productId: productId,
                userId: userId,
                pauseOptionId: pauseOptionId
            )
            ZSLogger.info("Subscription paused: product=\(productId), resumesAt=\(response.resumesAt?.description ?? "nil")", category: .iap)

            // Refresh entitlements to reflect the paused state
            _ = try? await restoreEntitlements(userId: userId)

            return response.resumesAt
        } catch {
            ZSLogger.error("Failed to pause subscription: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    /// Resume a paused subscription.
    ///
    /// Sends a resume request to the backend. On success, refreshes entitlements automatically.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to resume
    ///   - userId: Your app's user identifier
    public func resumeSubscription(productId: String, userId: String) async throws {
        guard let backend else {
            throw ZeroSettleError.notConfigured
        }

        do {
            try await backend.resumeSubscription(productId: productId, userId: userId)
            ZSLogger.info("Subscription resumed: product=\(productId)", category: .iap)

            // Refresh entitlements to reflect the active state
            _ = try? await restoreEntitlements(userId: userId)
        } catch {
            ZSLogger.error("Failed to resume subscription: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    /// Cancel a subscription.
    ///
    /// Sends a cancellation request to the backend. On success, refreshes entitlements automatically.
    /// For a cancel flow with UI (questionnaire + retention), use ``presentCancelFlow(productId:userId:)`` instead.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to cancel
    ///   - userId: Your app's user identifier
    ///   - immediate: If `true`, cancel immediately. If `false` (default), cancel at the end of the current billing period.
    public func cancelSubscription(productId: String, userId: String, immediate: Bool = false) async throws {
        guard let backend else {
            throw ZeroSettleError.notConfigured
        }

        do {
            try await backend.cancelSubscription(productId: productId, userId: userId, immediate: immediate)
            ZSLogger.info("Subscription cancelled: product=\(productId), immediate=\(immediate)", category: .iap)

            // Refresh entitlements to reflect the cancelled state
            _ = try? await restoreEntitlements(userId: userId)
        } catch {
            ZSLogger.error("Failed to cancel subscription: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
    }

    // MARK: - Upgrade Offer

    /// Present the upgrade offer sheet for a subscription upgrade.
    ///
    /// Fetches the upgrade offer configuration from the backend, then presents a
    /// native SwiftUI sheet with the savings pitch. If no upgrade is available,
    /// returns `.dismissed` immediately.
    ///
    /// The response (outcome) is automatically submitted to the backend when the
    /// user completes or dismisses the flow.
    ///
    /// - Parameters:
    ///   - productId: Optional product to check upgrade for (backend may auto-detect)
    ///   - userId: Your app's user identifier
    /// - Returns: The upgrade offer outcome (`.upgraded`, `.declined`, or `.dismissed`)
    public func presentUpgradeOffer(productId: String? = nil, userId: String) async -> UpgradeOffer.Result {
        guard let backend else {
            ZSLogger.error("presentUpgradeOffer called but SDK not configured", category: .iap)
            return .dismissed
        }

        let config: UpgradeOffer.Config
        do {
            config = try await backend.fetchUpgradeOffer(userId: userId, productId: productId)
        } catch {
            ZSLogger.error("Failed to fetch upgrade offer config: \(error)", category: .iap)
            return .dismissed
        }

        guard config.available,
              let currentProduct = config.currentProduct,
              let targetProduct = config.targetProduct else {
            ZSLogger.info("Upgrade offer not available: \(config.reason?.rawString ?? "unknown")", category: .iap)
            return .dismissed
        }

        let presenter = UpgradeOfferPresenter()
        let result = await presenter.present(
            config: config,
            userId: userId,
            backend: backend
        )

        // Fire-and-forget: submit response to backend
        Task {
            do {
                try await backend.respondUpgradeOffer(UpgradeOffer.RespondRequest(
                    userId: userId,
                    currentProductId: currentProduct.referenceId,
                    targetProductId: targetProduct.referenceId,
                    outcome: result.outcomeName,
                    variantId: config.variantId
                ))
                ZSLogger.debug("Upgrade offer response submitted", category: .iap)
            } catch {
                ZSLogger.error("Failed to submit upgrade offer response: \(error)", category: .iap)
            }
        }

        ZSLogger.info("Upgrade offer completed with result: \(result.outcomeName)", category: .iap)
        return result
    }

    /// Fetch the upgrade offer configuration without presenting any UI.
    ///
    /// Use this for checking availability or building custom upgrade offer experiences.
    ///
    /// - Parameters:
    ///   - productId: Optional product to check upgrade for
    ///   - userId: Your app's user identifier
    /// - Returns: The upgrade offer ``UpgradeOffer/Config``
    public func fetchUpgradeOfferConfig(productId: String? = nil, userId: String) async throws -> UpgradeOffer.Config {
        guard let backend else {
            throw ZeroSettleError.notConfigured
        }

        do {
            let config = try await backend.fetchUpgradeOffer(userId: userId, productId: productId)
            ZSLogger.info("Fetched upgrade offer config: available=\(config.available), reason=\(config.reason?.rawString ?? "none")", category: .iap)
            return config
        } catch {
            ZSLogger.error("Failed to fetch upgrade offer config: \(error)", category: .iap)
            throw Backend.wrapError(error)
        }
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

    /// Load and cache the cancel flow configuration. Non-throwing — logs errors and continues.
    private func loadCancelFlowConfig(userId: String? = nil) async {
        guard let backend else { return }
        do {
            let config = try await backend.fetchCancelFlow(userId: userId)
            cancelFlowConfig = config
            ZSLogger.info("Cancel flow config loaded: enabled=\(config.enabled), questions=\(config.questions.count)", category: .iap)
        } catch {
            ZSLogger.error("Failed to load cancel flow config during bootstrap: \(error)", category: .iap)
        }
    }

    /// Detect the user's jurisdiction from the App Store storefront.
    /// Falls back to `.row` (most restrictive) if storefront is unavailable
    /// (e.g., user not signed into App Store on Simulator).
    private func detectJurisdiction() async {
        if #available(iOS 16.0, *) {
            if let storefront = await Storefront.current {
                let jurisdiction = Jurisdiction.from(storefrontCountryCode: storefront.countryCode)
                detectedJurisdiction = jurisdiction
                ZSLogger.info("Detected jurisdiction: \(jurisdiction.rawValue) (storefront: \(storefront.countryCode))", category: .iap)
                return
            }
        }
        // Fallback: no storefront available → default to ROW (most restrictive)
        detectedJurisdiction = .row
        ZSLogger.info("Storefront unavailable, defaulting to ROW jurisdiction", category: .iap)
    }

    /// Process a checkout callback after the universal link is received.
    /// Verifies the transaction via the shared `Backend.verifyTransaction()` method,
    /// fires delegate callbacks, refreshes entitlements, and — if `purchase()` is
    /// awaiting — resumes its continuation with the result.
    private func processCheckoutCallback(_ callback: CheckoutCallback) async {
        pendingCheckout = false

        guard callback.success else {
            ZSLogger.info("Checkout cancelled for product: \(callback.productId)", category: .iap)
            delegate?.zeroSettleCheckoutDidCancel(productId: callback.productId)
            return
        }

        guard let backend else { return }

        do {
            // Use verifyTransaction (with polling) instead of a single getTransaction,
            // since the Stripe webhook may not have processed yet even though
            // the redirect URL says success.
            let transaction = try await backend.verifyTransaction(transactionId: callback.transactionId)

            ZSLogger.info("Checkout \(transaction.status == .processing ? "processing" : "completed"): \(transaction.id) for \(transaction.productId)", category: .iap)
            delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)

            await refreshEntitlementsAfterCheckout(transaction: transaction)

        } catch {
            ZSLogger.error("Transaction verification failed: \(error)", category: .iap)
            delegate?.zeroSettleCheckoutDidFail(
                productId: callback.productId,
                error: ZeroSettleError.transactionVerificationFailed(error.localizedDescription)
            )
        }
    }

    /// Refresh entitlements after a successful checkout.
    /// Fetches fresh entitlements from the backend and merges with StoreKit entitlements.
    /// Falls back to creating a local entitlement if the backend call fails.
    private func refreshEntitlementsAfterCheckout(transaction: CheckoutTransaction) async {
        guard let backend else { return }

        if let userId = storeKitManager?.currentUserId {
            do {
                let freshEntitlements = try await backend.getEntitlements(userId: userId)
                let storeKitEnts = entitlements.filter { $0.source == .storeKit }
                updateEntitlements(storeKitEnts + freshEntitlements)
                ZSLogger.info("Refreshed entitlements after checkout: \(freshEntitlements.count) web entitlements", category: .iap)
            } catch {
                ZSLogger.error("Failed to refresh entitlements after checkout: \(error)", category: .iap)
                appendLocalEntitlement(for: transaction)
            }
        } else {
            appendLocalEntitlement(for: transaction)
        }
    }

    /// Create and append a local entitlement from a transaction when backend fetch fails.
    private func appendLocalEntitlement(for transaction: CheckoutTransaction) {
        ZSLogger.info("Creating local fallback entitlement for \(transaction.productId) (transaction: \(transaction.id)). This entitlement was not fetched from the backend — it will be reconciled on the next restoreEntitlements() call.", category: .iap)
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

}

// MARK: - StoreKit Update Delegate

extension ZeroSettle: StoreKitUpdateDelegate {
    nonisolated func storeKitDidSyncTransaction(productId: String, transactionId: UInt64) {
        Task { @MainActor in
            delegate?.zeroSettleDidSyncStoreKitTransaction(
                productId: productId,
                transactionId: transactionId
            )
        }
    }

    nonisolated func storeKitSyncFailed(error: Error) {
        Task { @MainActor in
            delegate?.zeroSettleStoreKitSyncFailed(error: error)
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
