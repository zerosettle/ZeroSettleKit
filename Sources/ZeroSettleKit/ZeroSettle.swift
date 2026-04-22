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

    /// The userId provided was empty or whitespace-only.
    case invalidUserId

    /// Returns `true` if the error represents a user-initiated cancellation,
    /// regardless of which layer threw it (ZeroSettleKit, StoreKit, or Swift concurrency).
    public static func isCancellation(_ error: Error) -> Bool {
        if let zsError = error as? ZeroSettleError, case .cancelled = zsError { return true }
        if error is CancellationError { return true }
        if let skError = error as? StoreKitError, case .userCancelled = skError { return true }
        if let psError = error as? PaymentSheetError, case .cancelled = psError { return true }
        return false
    }

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
        case .invalidUserId:
            return "Invalid userId: must be a non-empty string."
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
@Observable
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
        ///
        /// The key prefix determines sandbox vs live mode (`zs_pk_test_` vs `zs_pk_live_`).
        public let publishableKey: String

        /// Whether to listen for and forward native StoreKit transactions to ZeroSettle.
        ///
        /// Set to `false` if you use RevenueCat (which handles StoreKit reporting itself). Defaults to `true`.
        public let syncStoreKitTransactions: Bool

        /// Apple Pay merchant identifier for native pay checkout.
        ///
        /// Required when using the `NativePay` package trait. If nil, the SDK uses the merchant ID from the backend
        /// config (managed mode default).
        public let appleMerchantId: String?

        /// Whether to automatically preload checkout sessions for all products after ``ZeroSettle/bootstrap(userId:)``
        /// completes.
        ///
        /// This will preload PaymentIntent and SetupIntent primitives via Stripe, but will not initiate any type of
        /// transaction until the user goes through the flow. When `true`, the first checkout opens instantly with no
        /// network delay. Defaults to `false`.
        public let preloadCheckout: Bool

        /// Maximum number of WKWebViews to pre-render in the background pool.
        ///
        /// Each WebView costs ~3-7 MB of memory. Set to `nil` (the default) for no limit (all products), or a positive
        /// `Int` to cap the pool size. Set to `0` to disable WebView pre-rendering entirely (PI caching still works).
        public let maxPreloadedWebViews: Int?

        public init(
            publishableKey: String,
            syncStoreKitTransactions: Bool = true,
            appleMerchantId: String? = nil,
            preloadCheckout: Bool = false,
            maxPreloadedWebViews: Int? = nil
        ) {
            self.publishableKey = publishableKey
            self.syncStoreKitTransactions = syncStoreKitTransactions
            self.appleMerchantId = appleMerchantId
            self.preloadCheckout = preloadCheckout
            self.maxPreloadedWebViews = maxPreloadedWebViews
        }

        internal var backendURL: URL {
            URL(string: "https://api.zerosettle.io/v1")!
        }
    }

    // MARK: - Observable State

    /// Whether the SDK has been configured.
    public private(set) var isConfigured: Bool = false

    /// Cached products from the last `fetchProducts()` call.
    public private(set) var products: [ZSProduct] = []

    /// All entitlements (merged from StoreKit and web checkout sources), including expired.
    ///
    /// > Important: For most app logic (feature gating, billing detection, UI display),
    /// > use ``activeEntitlements`` instead. This property includes expired and revoked
    /// > entitlements that can lead to incorrect routing if not filtered.
    ///
    /// **SwiftUI**: Read directly from `ZeroSettle.shared` — the class is `@Observable`
    /// and drives view updates automatically.
    ///
    /// For UIKit or structured concurrency alternatives, see ``ZeroSettleDelegate`` and
    /// ``entitlementUpdates``.
    public private(set) var entitlements: [Entitlement] = []

    /// Whether a web checkout is currently in progress (user is in Safari).
    public private(set) var pendingCheckout: Bool = false

    /// Remote configuration from the backend (populated after `fetchProducts()`).
    /// Contains checkout type settings and optional migration campaign data.
    public private(set) var remoteConfig: RemoteConfig?

    /// The detected jurisdiction based on the user's App Store storefront.
    /// Populated after `fetchProducts()`. Defaults to `.row` if detection fails.
    public private(set) var detectedJurisdiction: Jurisdiction?

    /// Whether ``bootstrap(userId:)`` has completed.
    public private(set) var isBootstrapped: Bool = false

    /// Original transaction IDs confirmed as owned by the current user during bootstrap.
    /// Used to filter local StoreKit entitlements so transactions belonging to other
    /// ZeroSettle accounts (on the same Apple ID) are excluded.
    /// nil = no filter applied (backward compat / no sync ran yet).
    private var ownedStoreKitTransactionIds: Set<String>?

    /// Filters StoreKit entitlements to only include those owned by the current user.
    /// If no ownership set exists (no sync ran yet), returns all entitlements unfiltered.
    private func filterOwnedEntitlements(_ entitlements: [Entitlement]) -> [Entitlement] {
        guard let ownedIds = ownedStoreKitTransactionIds else {
            ZSLogger.info("[filterOwnedEntitlements] ownedIds=nil → passing all \(entitlements.count) entitlement(s) unfiltered", category: .entitlements)
            return entitlements
        }
        let filtered = entitlements.filter { ent in
            guard let origId = ent.storekitOriginalTransactionId else { return true }
            return ownedIds.contains(origId)
        }
        ZSLogger.info("[filterOwnedEntitlements] ownedIds=\(ownedIds) input=\(entitlements.map { "\($0.productId)/orig=\($0.storekitOriginalTransactionId ?? "nil")" }) → kept \(filtered.count)/\(entitlements.count)", category: .entitlements)
        return filtered
    }

    /// Cached cancel flow configuration from the backend.
    /// Populated during ``bootstrap(userId:)`` so it's immediately available
    /// for building custom cancel flow UI without an extra network call.
    public private(set) var cancelFlowConfig: CancelFlow.Config?

    /// Migration manager for the StoreKit → web checkout migration flow.
    /// Access via ``migrationManager(for:)`` to guarantee a single shared instance.
    /// Starts in `.loading` and transitions after bootstrap completes.
    @available(*, deprecated, message: "Use offerManager(for:) instead")
    public private(set) var migrationManager: ZSMigrationManager?

    /// Unified offer manager for migration, storekit_to_web, and web_to_web flows.
    /// Access via ``offerManager(for:stripeCustomerId:)`` to guarantee a single shared instance.
    /// Starts in `.loading` and transitions after bootstrap completes.
    public private(set) var offerManager: ZSOfferManager?

    // MARK: - Customer Info

    /// Customer name included in all subsequent checkout requests.
    /// Set via ``bootstrap(userId:name:email:)`` or ``setCustomer(name:email:)``.
    /// Cleared by ``logout()``.
    public private(set) var customerName: String?

    /// Customer email included in all subsequent checkout requests.
    /// Set via ``bootstrap(userId:name:email:)`` or ``setCustomer(name:email:)``.
    /// Cleared by ``logout()``.
    public private(set) var customerEmail: String?

    // MARK: - Async Observation

    /// An `AsyncStream` that emits **all** entitlements (including expired) whenever they change.
    ///
    /// Filter with `\.isActive` for app logic:
    /// ```swift
    /// for await entitlements in ZeroSettle.shared.entitlementUpdates {
    ///     let active = entitlements.filter(\.isActive)
    ///     updateUI(with: active)
    /// }
    /// ```
    @ObservationIgnored
    public private(set) lazy var entitlementUpdates: AsyncStream<[Entitlement]> = {
        AsyncStream { [weak self] continuation in
            self?.entitlementContinuation = continuation
        }
    }()

    /// Backing continuation for the entitlements async stream.
    @ObservationIgnored
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

    // MARK: - Convenience Lookups

    /// Returns the product with the given ID, if loaded.
    public func product(for id: String) -> ZSProduct? {
        products.first(where: { $0.id == id })
    }

    /// All currently active entitlements (any source).
    ///
    /// Use this for most app logic: feature gating, billing provider detection,
    /// subscription status display, and cancel flow routing. Excludes expired,
    /// revoked, and inactive entitlements that can cause incorrect behavior.
    public var activeEntitlements: [Entitlement] {
        entitlements.filter(\.isActive)
    }

    /// Whether the user has an active entitlement for the given product ID.
    public func hasActiveEntitlement(for productId: String) -> Bool {
        activeEntitlements.contains(where: { $0.productId == productId })
    }

    /// Returns web-checkout entitlements whose IDs are not in the given set.
    /// Use this to detect new consumable purchases from web checkout that haven't
    /// been credited yet, avoiding double-counting.
    public func newConsumableEntitlements(excluding knownIds: Set<String>) -> [Entitlement] {
        activeEntitlements.filter { $0.source == .webCheckout && !knownIds.contains($0.id) }
    }

    // MARK: - Entitlement Claiming

    /// Claims a StoreKit entitlement for the current user, even if another
    /// ZeroSettle account originally purchased it on this Apple ID.
    ///
    /// Use this for:
    /// - **Testing**: switching between accounts on the same Apple sandbox ID
    /// - **Account migration**: moving a subscription to a new account
    /// - **Support**: resolving "wrong account" issues
    ///
    /// Only applicable to subscriptions and non-consumables. Consumables cannot
    /// be claimed.
    ///
    /// Requires ``bootstrap(userId:)`` to have been called first.
    ///
    /// ```swift
    /// try await ZeroSettle.shared.claimEntitlement(
    ///     productId: "com.myapp.premium.monthly"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - productId: The product to claim from the current Apple ID's transactions.
    ///   - userId: The current user's ID. Must match the ID used in ``bootstrap(userId:)``.
    /// - Throws: ``ZeroSettleError`` if the product is not found in StoreKit transactions,
    ///   or if the server rejects the claim.
    @MainActor
    public func claimEntitlement(productId: String, userId: String) async throws {
        let backend = try requireBackend()

        guard let storeKitManager else {
            throw ZeroSettleError.notConfigured
        }

        // Find the StoreKit transaction for this product on the current Apple ID
        guard let jwsRepresentation = await storeKitManager.findTransactionJWS(for: productId) else {
            throw ZeroSettleError.productNotFound(productId)
        }

        let response = try await backend.claimEntitlement(
            jwsRepresentation: jwsRepresentation,
            userId: userId
        )

        ZSLogger.info("[ZeroSettle] Entitlement claimed: product=\(productId) claimed=\(response.claimed ?? false) message=\(response.message ?? "")", category: .entitlements)

        // Add the claimed product to our owned set so it passes the filter
        if let origTxnId = response.originalTransactionId {
            ownedStoreKitTransactionIds?.insert(origTxnId)
        }

        // Claim transferred an entitlement to us — surface it to downstream
        // consumers (ZSOfferManager, Switch & Save, debug env view) without
        // waiting for the restoreEntitlements fetch below.
        if response.claimed == true {
            await refreshEntitlementsAndPublish()
        }

        // Refresh entitlements to pick up the new claim
        _ = try await restoreEntitlements(userId: userId)
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

    // MARK: - Customer Info API

    /// Update customer name and/or email for subsequent checkout requests.
    ///
    /// Use this for mid-session updates (e.g., user edits their profile).
    /// For initial setup, prefer passing `name`/`email` to ``bootstrap(userId:name:email:)``.
    /// Both values are cleared by ``logout()``.
    ///
    /// - Parameters:
    ///   - name: Customer name, or `nil` to leave unchanged
    ///   - email: Customer email, or `nil` to leave unchanged
    public func setCustomer(name: String? = nil, email: String? = nil) {
        if let name { self.customerName = name }
        if let email { self.customerEmail = email }
    }

    // MARK: - Logout

    /// Clears all user-scoped state, resetting the SDK to pre-bootstrap condition.
    ///
    /// Call this when the current user logs out of your app. After `logout()`,
    /// the SDK is still configured — call ``bootstrap(userId:name:email:)`` for
    /// the next user.
    ///
    /// **What is cleared** (user-scoped):
    /// - `customerName`, `customerEmail`
    /// - `isBootstrapped`, `entitlements`, `remoteConfig`, `cancelFlowConfig`
    /// - `migrationManager`, `offerManager`
    /// - Cached checkout sessions (PaymentIntents for the previous user)
    /// - StoreKit listener userId
    ///
    /// **What is preserved** (app-scoped):
    /// - `products` (same catalog for all users)
    /// - `detectedJurisdiction` (device-level storefront)
    /// - SDK configuration (`isConfigured`, publishable key)
    public func logout() {
        // User identity
        customerName = nil
        customerEmail = nil

        // Bootstrap state
        isBootstrapped = false
        entitlements = []
        entitlementContinuation?.yield([])
        delegate?.zeroSettleEntitlementsDidUpdate([])
        remoteConfig = nil
        cancelFlowConfig = nil
        migrationManager = nil
        offerManager = nil
        ownedStoreKitTransactionIds = nil

        // Cached checkout sessions (PaymentIntents for previous user)
        Task { await CheckoutResponseCache.shared.clearAll() }

        // StoreKit listener userId
        storeKitManager?.setUserId(nil)
    }

    // MARK: - Delegate

    /// Delegate to receive IAP event callbacks.
    @ObservationIgnored
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

    /// Update entitlements and notify all observers (delegate + AsyncStream +
    /// SwiftUI bindings).
    ///
    /// `ZeroSettle` is annotated with both `@Observable` (for `withObservationTracking`
    /// consumers like ``ZSOfferManager``) and `ObservableObject` (for legacy
    /// `@ObservedObject` / `@StateObject` consumers reading `ZeroSettle.shared`).
    /// The `@Observable` macro does NOT publish to `objectWillChange` — so views
    /// that adopt the `ObservableObject` protocol would miss updates unless we
    /// send manually. We do both on every mutation to guarantee downstream
    /// re-renders regardless of which observation style the app chose.
    private func updateEntitlements(_ newEntitlements: [Entitlement]) {
        guard entitlements != newEntitlements else { return }
        objectWillChange.send()
        entitlements = newEntitlements
        entitlementContinuation?.yield(newEntitlements)
        delegate?.zeroSettleEntitlementsDidUpdate(newEntitlements)
    }

    // MARK: - Private State

    @ObservationIgnored
    private var config: Configuration?
    @ObservationIgnored
    private var backend: Backend?
    @ObservationIgnored
    private var checkoutFlow: WebCheckoutFlow?
    @ObservationIgnored
    private var storeKitManager: StoreKitManager?

    /// Observes StoreKit subscription state changes (cancel, revoke, expire)
    /// locally. Used by `ZSOfferManager` / `ZSMigrationManager` to transition
    /// to terminal UI states the moment the user cancels in App Store Settings
    /// — no ASSN / backend round-trip required. See ``StoreKitSubscriptionMonitor``.
    @ObservationIgnored
    internal let subscriptionMonitor = StoreKitSubscriptionMonitor()

#if NativePay
    @ObservationIgnored
    private var nativePayFlow: NativePay.Flow?
#endif

    /// Whether `.zeroSettleHandler()` has been installed on a view.
    /// Used to warn developers in DEBUG builds if they forget the modifier.
    @ObservationIgnored
    internal var handlerInstalled: Bool = false

    // MARK: - Initialization

    private init() {}

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
        Task { await CheckoutResponseCache.shared.clearAll() }

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

#if NativePay
        self.nativePayFlow = NativePay.Flow(backend: backend)
#endif

        if config.syncStoreKitTransactions {
            let storeKitManager = StoreKitManager(backend: backend, subscriptionMonitor: subscriptionMonitor)
            storeKitManager.delegate = self
            storeKitManager.startListening()
            self.storeKitManager = storeKitManager
        }

        // Local subscription monitor runs regardless of `syncStoreKitTransactions`
        // — consumers (ZSOfferManager, ZSMigrationManager) rely on it to flip
        // to terminal UI states when the user cancels Apple auto-renew. Even
        // RevenueCat-integrated apps benefit from local UI updates.
        subscriptionMonitor.start()

        isConfigured = true

        let mode = config.publishableKey.hasPrefix("zs_pk_test_") ? "sandbox" : "live"
        ZSLogger.info("ZeroSettle configured (mode=\(mode))", category: .general)
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
    /// try await ZeroSettle.shared.bootstrap(
    ///     userId: currentUser.id,
    ///     name: "Jane Doe",
    ///     email: "jane@example.com"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - userId: Your app's user identifier for fetching entitlements and migration data
    ///   - name: Optional customer name to associate with the Stripe Customer
    ///   - email: Optional customer email to associate with the Stripe Customer
    /// - Returns: A ``ProductCatalog`` containing products and remote configuration
    @discardableResult
    public func bootstrap(userId: String, name: String? = nil, email: String? = nil) async throws -> ProductCatalog {
        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ZSLogger.error("bootstrap() called with empty userId — this is a no-op. Pass a valid user identifier.", category: .entitlements)
            throw ZeroSettleError.invalidUserId
        }

        // Reset user-scoped state so back-to-back bootstrap() calls (with or
        // without an intervening logout()) never leak data across users.
        customerName = nil
        customerEmail = nil
        isBootstrapped = false
        entitlements = []
        entitlementContinuation?.yield([])
        delegate?.zeroSettleEntitlementsDidUpdate([])
        remoteConfig = nil
        cancelFlowConfig = nil
        migrationManager = nil
        offerManager = nil
        ownedStoreKitTransactionIds = nil
        Task { await CheckoutResponseCache.shared.clearAll() }

        // Store customer info for subsequent checkout requests.
        self.customerName = name
        self.customerEmail = email

        // 1. Sync StoreKit transactions to the backend so the Identity and
        //    Entitlement records exist before we check migration eligibility.
        if let storeKitManager {
            storeKitManager.setUserId(userId)
            ownedStoreKitTransactionIds = await storeKitManager.syncCurrentTransactions(userId: userId)
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

        // 5. Ensure unified offer manager exists alongside migration manager.
        _ = offerManager(for: userId)

        // 6. Pre-create PaymentIntents so the first checkout opens instantly.
        if currentConfig?.preloadCheckout != false {
            Task { await CheckoutSheet<EmptyView>.warmUpAll(userId: userId) }
        }

        return catalog
    }

    // MARK: - Migration Manager

    /// Returns the shared migration manager, creating one if it doesn't exist yet.
    ///
    /// Both ``MigrationTipView`` and ``bootstrap(userId:)`` call this to guarantee
    /// a single shared instance. The manager starts in `.loading` and transitions
    /// to `.eligible` or `.ineligible` once bootstrap completes (via Combine).
    ///
    /// - Parameters:
    ///   - userId: Your app's user identifier
    ///   - stripeCustomerId: Optional existing Stripe Customer ID (`cus_xxx`)
    ///     to attach the checkout to.
    /// - Returns: The shared ``ZSMigrationManager``
    @discardableResult
    public func migrationManager(for userId: String, stripeCustomerId: String? = nil) -> ZSMigrationManager {
        if let existing = migrationManager { return existing }
        let manager = ZSMigrationManager(userId: userId, stripeCustomerId: stripeCustomerId)
        migrationManager = manager
        return manager
    }

    // MARK: - Offer Manager

    /// Returns the shared offer manager, creating one if it doesn't exist yet.
    ///
    /// Both ``OfferTipView`` and ``bootstrap(userId:)`` call this to guarantee
    /// a single shared instance. The manager starts in `.loading` and transitions
    /// to `.eligible` or `.ineligible` once bootstrap completes (via notification).
    ///
    /// - Parameters:
    ///   - userId: Your app's user identifier
    ///   - stripeCustomerId: Optional existing Stripe Customer ID (`cus_xxx`)
    ///     to attach the checkout to.
    /// - Returns: The shared ``ZSOfferManager``
    @discardableResult
    public func offerManager(for userId: String, stripeCustomerId: String? = nil) -> ZSOfferManager {
        if let existing = offerManager { return existing }
        let manager = ZSOfferManager(userId: userId, stripeCustomerId: stripeCustomerId)
        offerManager = manager
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
        let backend = try requireBackend()

        do {
            // 1. Fetch from ZeroSettle backend (includes config when userId is provided)
            let catalog = try await backend.fetchProducts(userId: userId)
            var products = catalog.products

            if let config = catalog.config {
                remoteConfig = config
            }

            // Detect jurisdiction from App Store storefront
            await detectJurisdiction()

            // 2. Try to fetch ALL products from StoreKit (let StoreKit tell us what exists)
            let allProductIds = products.map { $0.id }

            // 3. Clean up expired unfinished transactions before purchasing
            if let storeKitManager {
                await storeKitManager.finishExpiredTransactions()
            }

            // 4. Fetch StoreKit products (if StoreKit sync enabled)
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
                if matched < products.count {
                    ZSLogger.info("\(products.count - matched) product(s) not found in StoreKit", category: .general)
                }
            }

            self.products = products
            return ProductCatalog(products: products, config: catalog.config)
        } catch {
            ZSLogger.error("Failed to fetch products: \(error)", category: .general)
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
            ZSLogger.error(".zeroSettleHandler() is not installed on any view. Universal link callbacks from Safari checkout will not be received. Add .zeroSettleHandler() to your root view.", category: .checkout)
        }
#endif

        // Subscriptions and non-consumables require a userId for entitlement tracking
        if let product = products.first(where: { $0.id == productId }) {
            try validateUserIdIfRequired(for: product, userId: userId)
        }

        // Log the effective checkout routing decision
        let effectiveJurisdiction = detectedJurisdiction ?? .row
        let effectiveType = checkoutType
        ZSLogger.info("Checkout routing: product=\(productId), jurisdiction=\(effectiveJurisdiction.rawValue), checkoutType=\(effectiveType.rawValue), webCheckoutEnabled=\(isWebCheckoutEnabled)", category: .checkout)

        // Check if web checkout is enabled for the detected jurisdiction
        if !isWebCheckoutEnabled {
            ZSLogger.error("Web checkout disabled for \(effectiveJurisdiction.rawValue) jurisdiction. The SDK will throw webCheckoutDisabledForJurisdiction. Configure this in your ZeroSettle dashboard under Checkout Configuration.", category: .checkout)
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
                ZSLogger.info("Starting native Apple Pay checkout for \(productId)", category: .checkout)
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
                    ZSLogger.error("Native Apple Pay failed for \(productId): \(error)", category: .checkout)
                    delegate?.zeroSettleCheckoutDidFail(productId: productId, error: error)
                    throw ZeroSettleError.checkoutFailed(reason: .other(error.localizedDescription))
                }
            } else {
                // Log the specific reason for fallback
                if resolvedMerchantId == nil {
                    ZSLogger.info("Native Pay fallback → webview: no appleMerchantId configured. Pass appleMerchantId in Configuration or configure apple_merchant_id on the backend.", category: .checkout)
                } else if !nativePayFlow.canMakePayments() {
                    ZSLogger.info("Native Pay fallback → webview: Apple Pay is not available on this device (no cards configured or device doesn't support Apple Pay).", category: .checkout)
                }
            }
        }
#endif

        do {
            let session = try await checkoutFlow.beginCheckout(
                productId: productId,
                userId: userId
            )

            ZSLogger.info("Checkout browser dismissed for \(productId), transaction: \(session.transactionId ?? "none")", category: .checkout)

            // Brief pause to allow the universal link callback to process.
            // The foreground notification fires before scene(_:continue:),
            // which dispatches processCheckoutCallback in a separate Task on
            // @MainActor. A single Task.yield() is insufficient — it doesn't
            // guarantee the callback Task has been scheduled and executed.
            try? await Task.sleep(nanoseconds: 300_000_000)

            // If the universal link callback already fired, pendingCheckout is false
            // and processCheckoutCallback already handled delegate/entitlements.
            if !pendingCheckout {
                ZSLogger.debug("Callback already processed via universal link", category: .checkout)
                if let transactionId = session.transactionId {
                    let transaction = try await backend.getTransaction(transactionId: transactionId)
                    return transaction
                }
                throw ZeroSettleError.cancelled
            }

            // No callback — verify the transaction with the backend before
            // assuming the user abandoned. The Stripe webhook may still be
            // processing, so verifyTransaction polls until confirmed.
            // This is the primary completion path for Safari / SafariVC
            // checkouts (universal links are unreliable in practice).
            if let transactionId = session.transactionId {
                ZSLogger.debug("No callback — verifying transaction \(transactionId) with backend", category: .checkout)
                do {
                    let transaction = try await backend.verifyTransaction(transactionId: transactionId)
                    ZSLogger.info("Transaction \(transactionId) confirmed via backend verification", category: .checkout)
                    pendingCheckout = false
                    delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                    await refreshEntitlementsAfterCheckout(transaction: transaction)
                    return transaction
                } catch {
                    ZSLogger.debug("Transaction \(transactionId) not completed: \(error)", category: .checkout)
                }
            }

            // User truly abandoned — no callback and transaction not completed.
            pendingCheckout = false
            delegate?.zeroSettleCheckoutDidCancel(productId: productId)
            throw ZeroSettleError.cancelled
        } catch let error as ZeroSettleError {
            pendingCheckout = false
            throw error
        } catch {
            pendingCheckout = false
            ZSLogger.error("Checkout failed for \(productId): \(error)", category: .checkout)
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

        do {
            return try await storeKitManager.purchase(skProduct)
        } catch let error as StoreKitPurchaseError {
            switch error {
            case .productNotFound(let id):
                throw ZeroSettleError.productNotFound(id)
            case .verificationFailed(let underlying):
                throw ZeroSettleError.storeKitVerificationFailed(underlyingError: underlying)
            case .userCancelled:
                throw ZeroSettleError.cancelled
            case .pending:
                throw ZeroSettleError.purchasePending
            case .unknown:
                throw ZeroSettleError.checkoutFailed(reason: .other("Unknown StoreKit error"))
            }
        }
    }

    // MARK: - Migration Tracking

    /// Track a successful migration conversion.
    /// Call this after a user successfully completes a web checkout purchase
    /// as part of a migration campaign (switching from StoreKit to web checkout).
    ///
    /// - Parameter userId: Your app's user identifier
    public func trackMigrationConversion(userId: String) async throws {
        let backend = try requireBackend()

        do {
            try await backend.trackMigrationConversion(userId: userId)
            ZSLogger.info("Migration conversion tracked for user: \(userId)", category: .migration)
        } catch {
            ZSLogger.error("Failed to track migration conversion: \(error)", category: .migration)
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
                ZSLogger.debug("trackEvent: SDK not configured, dropping event", category: .general)
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
                ZSLogger.debug("trackEvent: \(type.rawValue) sent for product=\(productId)", category: .general)
            } catch {
                ZSLogger.debug("trackEvent: failed to send \(type.rawValue): \(error)", category: .general)
            }
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
        ZSLogger.info("Incoming URL: \(url.absoluteString)", category: .deepLinks)

        guard let checkoutFlow else {
            ZSLogger.error("checkoutFlow is nil — SDK not configured", category: .deepLinks)
            return false
        }

        ZSLogger.debug("checkoutFlow exists, parsing callback...", category: .deepLinks)
        guard let callback = checkoutFlow.handleCallback(url: url) else {
            ZSLogger.info("URL did not match checkout callback pattern", category: .deepLinks)
            return false
        }
        ZSLogger.info("Callback parsed: transaction=\(callback.transactionId), product=\(callback.productId), success=\(callback.success)", category: .deepLinks)

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
        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ZSLogger.error("restoreEntitlements() called with empty userId", category: .entitlements)
            throw ZeroSettleError.invalidUserId
        }

        let backend = try requireBackend()

        storeKitManager?.setUserId(userId)

        // Snapshot the prior list BEFORE we start fetching, so we can preserve
        // any locally-appended consumable fallbacks (ids prefixed "web_")
        // through the rebuild. Consumable web purchases don't get persisted as
        // backend EntitlementStates, so without this merge they'd be wiped
        // before the host app observes them via newConsumableEntitlements().
        let priorEntitlements = entitlements

        var allEntitlements: [Entitlement] = []

        if let storeKitManager {
            let storeKitEntitlements = await storeKitManager.getCurrentEntitlements()
            allEntitlements.append(contentsOf: filterOwnedEntitlements(storeKitEntitlements))
        }

        do {
            let webEntitlements = try await backend.getEntitlements(userId: userId)
            allEntitlements.append(contentsOf: webEntitlements)
        } catch {
            ZSLogger.error("Failed to fetch web entitlements: \(error)", category: .entitlements)
            let merged = EntitlementMerge.preservingLocalFallbacks(
                fresh: allEntitlements, prior: priorEntitlements
            )
            updateEntitlements(merged)
            throw ZeroSettleError.restoreEntitlementsFailed(
                partialEntitlements: merged,
                underlyingError: error
            )
        }

        let merged = EntitlementMerge.preservingLocalFallbacks(
            fresh: allEntitlements, prior: priorEntitlements
        )
        updateEntitlements(merged)
        ZSLogger.debug("Restored \(merged.count) entitlement(s) for userId=\"\(userId)\" (fresh=\(allEntitlements.count) preserved_fallbacks=\(merged.count - allEntitlements.count))", category: .entitlements)

        return merged
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
        let backend = try requireBackend()

        do {
            let transactions = try await backend.getTransactionHistory(userId: userId)
            ZSLogger.info("Fetched \(transactions.count) transactions for user: \(userId)", category: .entitlements)
            return transactions
        } catch {
            ZSLogger.error("Failed to fetch transaction history: \(error)", category: .entitlements)
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
        ZSLogger.info("presentCancelFlow called: productId=\(productId), userId=\(userId)", category: .cancelFlow)

        guard let backend else {
            ZSLogger.error("SDK not configured — returning .cancelled", category: .cancelFlow)
            return .cancelled
        }

        // Use cached config if available, otherwise fetch
        let config: CancelFlow.Config
        if let cached = cancelFlowConfig {
            ZSLogger.info("Using cached config: enabled=\(cached.enabled), questions=\(cached.questions.count)", category: .cancelFlow)
            config = cached
        } else {
            ZSLogger.info("No cached config, fetching from backend...", category: .cancelFlow)
            do {
                config = try await backend.fetchCancelFlow(userId: userId)
                cancelFlowConfig = config
                ZSLogger.info("Fetched config: enabled=\(config.enabled), questions=\(config.questions.count)", category: .cancelFlow)
            } catch {
                ZSLogger.error("Fetch failed: \(error) — returning .cancelled", category: .cancelFlow)
                return .cancelled
            }
        }

        // If cancel flow is not configured, return .dismissed so the app can handle fallback
        guard config.enabled, !config.questions.isEmpty else {
            ZSLogger.info("Not configured (enabled=\(config.enabled), questions=\(config.questions.count)) — returning .dismissed", category: .cancelFlow)
            return .dismissed
        }

        ZSLogger.info("Presenting questionnaire (\(config.questions.count) questions)", category: .cancelFlow)
        let presenter = CancelFlowPresenter()
        let result = await presenter.present(
            config: config,
            productId: productId,
            userId: userId,
            backend: backend
        )

        // Actually cancel the subscription when user confirms cancellation.
        // Cancel at period end (immediate: false) so the user keeps access until
        // their current billing cycle ends — standard cancellation UX.
        if result == .cancelled {
            // Prefer web checkout entitlement when both exist (e.g. after Switch & Save,
            // the StoreKit entitlement is still active but the user is now on web billing).
            let matchingEntitlements = activeEntitlements.filter { $0.productId == productId }
            let matchingEntitlement = matchingEntitlements.first(where: { $0.source == .webCheckout }) ?? matchingEntitlements.first
            let isStoreKit = matchingEntitlement?.source == .storeKit
            ZSLogger.info("Result=.cancelled, productId=\(productId), matchingEntitlement=\(matchingEntitlement?.id ?? "nil"), source=\(matchingEntitlement?.source.rawValue ?? "nil"), isStoreKit=\(isStoreKit)", category: .cancelFlow)

            if isStoreKit {
                ZSLogger.info("Opening Apple subscription management...", category: .cancelFlow)
                await openManageSubscriptions()
                ZSLogger.info("Apple subscription management dismissed", category: .cancelFlow)
            } else {
                ZSLogger.info("Calling cancel API for web subscription...", category: .cancelFlow)
                do {
                    try await cancelSubscription(productId: productId, userId: userId, immediate: false)
                    ZSLogger.info("Cancel API succeeded", category: .cancelFlow)
                } catch {
                    ZSLogger.error("Cancel API failed — subscription may still be active: \(error)", category: .cancelFlow)
                    // Return .dismissed instead of .cancelled so the caller knows the
                    // cancellation did not actually succeed on the backend.
                    return .dismissed
                }
            }
        }

        ZSLogger.info("Flow completed with result: \(result)", category: .cancelFlow)
        return result
    }

    // MARK: - Manage Subscriptions

    /// Open Apple's native subscription management UI.
    ///
    /// Falls back silently if no UIWindowScene is available (e.g., app extensions).
    @MainActor
    private func openManageSubscriptions() async {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            ZSLogger.error("No active UIWindowScene — cannot open subscription management", category: .cancelFlow)
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: windowScene)
        } catch {
            ZSLogger.error("Failed to open subscription management: \(error)", category: .cancelFlow)
        }
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
        let backend = try requireBackend()

        do {
            let config = try await backend.fetchCancelFlow(userId: userId)
            cancelFlowConfig = config
            ZSLogger.info("Fetched cancel flow config: enabled=\(config.enabled), questions=\(config.questions.count), pause=\(config.pause?.enabled ?? false)", category: .cancelFlow)
            return config
        } catch {
            ZSLogger.error("Failed to fetch cancel flow config: \(error)", category: .cancelFlow)
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
        let backend = try requireBackend()

        do {
            let response = try await backend.acceptSaveOffer(productId: productId, userId: userId)
            ZSLogger.info("Save offer accepted: product=\(productId), message=\(response.message)", category: .cancelFlow)

            // Refresh entitlements to reflect the updated subscription
            _ = try? await restoreEntitlements(userId: userId)

            return CancelFlow.SaveOfferResult(
                message: response.message,
                discountPercent: response.discountPercent,
                durationMonths: response.durationMonths
            )
        } catch {
            ZSLogger.error("Failed to accept save offer: \(error)", category: .cancelFlow)
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
            ZSLogger.error("submitCancelFlowResponse called but SDK not configured", category: .cancelFlow)
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
            },
            variantId: cancelFlowConfig?.variantId
        )

        do {
            try await backend.submitCancelFlowResponse(payload)
            ZSLogger.debug("Cancel flow response submitted", category: .cancelFlow)
        } catch {
            ZSLogger.error("Failed to submit cancel flow response: \(error)", category: .cancelFlow)
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
    public func pauseSubscription(productId: String, userId: String, pauseDurationDays: Int?) async throws -> Date? {
        let backend = try requireBackend()

        do {
            let response = try await backend.pauseSubscription(
                productId: productId,
                userId: userId,
                pauseDurationDays: pauseDurationDays
            )
            ZSLogger.info("Subscription paused: product=\(productId), resumesAt=\(response.resumesAt?.description ?? "nil")", category: .cancelFlow)

            // Refresh entitlements to reflect the paused state
            _ = try? await restoreEntitlements(userId: userId)

            return response.resumesAt
        } catch {
            ZSLogger.error("Failed to pause subscription: \(error)", category: .cancelFlow)
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
        let backend = try requireBackend()

        do {
            try await backend.resumeSubscription(productId: productId, userId: userId)
            ZSLogger.info("Subscription resumed: product=\(productId)", category: .cancelFlow)

            // Refresh entitlements to reflect the active state
            _ = try? await restoreEntitlements(userId: userId)
        } catch {
            ZSLogger.error("Failed to resume subscription: \(error)", category: .cancelFlow)
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
        let backend = try requireBackend()

        do {
            try await backend.cancelSubscription(productId: productId, userId: userId, immediate: immediate)
            ZSLogger.info("Subscription cancelled: product=\(productId), immediate=\(immediate)", category: .cancelFlow)

            // Refresh entitlements to reflect the cancelled state
            _ = try? await restoreEntitlements(userId: userId)
        } catch {
            ZSLogger.error("Failed to cancel subscription: \(error)", category: .cancelFlow)
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
            ZSLogger.error("presentUpgradeOffer called but SDK not configured", category: .checkout)
            return .dismissed
        }

        let config: UpgradeOffer.Config
        do {
            config = try await backend.fetchUpgradeOffer(userId: userId, productId: productId)
        } catch {
            ZSLogger.error("Failed to fetch upgrade offer config: \(error)", category: .checkout)
            return .dismissed
        }

        guard config.available,
              let currentProduct = config.currentProduct,
              let targetProduct = config.targetProduct else {
            ZSLogger.info("Upgrade offer not available: \(config.reason?.rawString ?? "unknown")", category: .checkout)
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
                ZSLogger.debug("Upgrade offer response submitted", category: .checkout)
            } catch {
                ZSLogger.error("Failed to submit upgrade offer response: \(error)", category: .checkout)
            }
        }

        ZSLogger.info("Upgrade offer completed with result: \(result.outcomeName)", category: .checkout)
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
        let backend = try requireBackend()

        do {
            let config = try await backend.fetchUpgradeOffer(userId: userId, productId: productId)
            ZSLogger.info("Fetched upgrade offer config: available=\(config.available), reason=\(config.reason?.rawString ?? "none")", category: .checkout)
            return config
        } catch {
            ZSLogger.error("Failed to fetch upgrade offer config: \(error)", category: .checkout)
            throw Backend.wrapError(error)
        }
    }

    // MARK: - User Offer (SDK 1.2+)

    /// Fetch the unified user-offer response from `/v1/iap/user-offer/` (SDK 1.2+).
    ///
    /// Returns a ``UserOffer/Response`` carrying both the user's current subscription
    /// state (``UserOffer/Subscription``) and the server-canonical offer decision
    /// (discriminated by ``UserOffer/ActionType``). The server resolves experiment
    /// variants and rollout eligibility, so the SDK no longer re-hashes locally.
    ///
    /// Adoption is optional — existing calls to ``fetchProducts(userId:)`` continue
    /// to return `config.offer` / `config.migration` in the legacy shape, and
    /// ``ZSOfferManager`` / ``ZSMigrationManager`` remain on that path.
    ///
    /// - Parameter userId: Your app's user identifier.
    /// - Returns: The unified ``UserOffer/Response``.
    public func fetchUserOffer(userId: String) async throws -> UserOffer.Response {
        let backend = try requireBackend()

        do {
            let response = try await backend.fetchUserOffer(userId: userId)
            ZSLogger.info("Fetched user offer: action=\(response.offer.actionType.rawValue), eligible=\(response.offer.isEligible)", category: .checkout)
            return response
        } catch {
            ZSLogger.error("Failed to fetch user offer: \(error)", category: .checkout)
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

    /// Unwrap the backend or throw ``ZeroSettleError/notConfigured``.
    private func requireBackend() throws -> Backend {
        guard let backend else { throw ZeroSettleError.notConfigured }
        return backend
    }

    /// Load and cache the cancel flow configuration. Non-throwing — logs errors and continues.
    private func loadCancelFlowConfig(userId: String? = nil) async {
        guard let backend else { return }
        do {
            let config = try await backend.fetchCancelFlow(userId: userId)
            cancelFlowConfig = config
        } catch {
            ZSLogger.error("Failed to load cancel flow config during bootstrap: \(error)", category: .cancelFlow)
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
                return
            }
        }
        // Fallback: no storefront available → default to ROW (most restrictive)
        detectedJurisdiction = .row
        ZSLogger.info("Storefront unavailable, defaulting to ROW jurisdiction", category: .general)
    }

    /// Process a checkout callback after the universal link is received.
    /// Verifies the transaction via the shared `Backend.verifyTransaction()` method,
    /// fires delegate callbacks, refreshes entitlements, and — if `purchase()` is
    /// awaiting — resumes its continuation with the result.
    private func processCheckoutCallback(_ callback: CheckoutCallback) async {
        pendingCheckout = false

        guard callback.success else {
            ZSLogger.info("Checkout cancelled for product: \(callback.productId)", category: .checkout)
            delegate?.zeroSettleCheckoutDidCancel(productId: callback.productId)
            return
        }

        guard let backend else { return }

        do {
            // Use verifyTransaction (with polling) instead of a single getTransaction,
            // since the Stripe webhook may not have processed yet even though
            // the redirect URL says success.
            let transaction = try await backend.verifyTransaction(transactionId: callback.transactionId)

            ZSLogger.info("Checkout \(transaction.status == .processing ? "processing" : "completed"): \(transaction.id) for \(transaction.productId)", category: .checkout)
            delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)

            await refreshEntitlementsAfterCheckout(transaction: transaction)

        } catch {
            ZSLogger.error("Transaction verification failed: \(error)", category: .checkout)
            delegate?.zeroSettleCheckoutDidFail(
                productId: callback.productId,
                error: ZeroSettleError.transactionVerificationFailed(error.localizedDescription)
            )
        }
    }

    /// Refetches entitlements from BOTH sources (StoreKit + backend) and
    /// publishes the merged result to observers.
    ///
    /// Call after any mutation that might have changed the user's entitlements
    /// (StoreKit sync, claim, web checkout completion, etc.) so downstream
    /// consumers (``ZSOfferManager``, Switch & Save, debug env view) see the
    /// new ownership state without requiring an app restart.
    ///
    /// Pulls StoreKit entitlements live via ``StoreKitManager/getCurrentEntitlements()``
    /// and applies the current ``filterOwnedEntitlements(_:)`` so claims that flip
    /// ownership of a StoreKit transaction show up immediately — the previous
    /// implementation reused `entitlements.filter { .storeKit }` which was stale
    /// (pre-claim) and would drop a freshly-claimed transaction until restart.
    ///
    /// No-op when no userId is set (pre-bootstrap). Errors are logged, not thrown.
    internal func refreshEntitlementsAndPublish() async {
        ZSLogger.info("refreshEntitlementsAndPublish invoked", category: .entitlements)

        guard let backend else {
            ZSLogger.debug("refreshEntitlementsAndPublish: no backend (pre-configure) — skipping", category: .entitlements)
            return
        }
        guard let userId = storeKitManager?.currentUserId else {
            ZSLogger.debug("refreshEntitlementsAndPublish: no userId (pre-bootstrap) — skipping", category: .entitlements)
            return
        }

        // Pull fresh StoreKit entitlements (post-claim ownership may have changed).
        var storeKitEnts: [Entitlement] = []
        if let storeKitManager {
            let fresh = await storeKitManager.getCurrentEntitlements()
            storeKitEnts = filterOwnedEntitlements(fresh)
        } else {
            // StoreKit sync disabled (RevenueCat mode) — keep whatever we had.
            storeKitEnts = entitlements.filter { $0.source == .storeKit }
        }

        do {
            let webEntitlements = try await backend.getEntitlements(userId: userId)
            updateEntitlements(storeKitEnts + webEntitlements)
            ZSLogger.debug("refreshEntitlementsAndPublish: published \(webEntitlements.count) web + \(storeKitEnts.count) storekit entitlement(s)", category: .entitlements)
        } catch {
            // Even when the backend call fails, republish the fresh StoreKit
            // slice so claims that changed local ownership surface to the UI.
            let webEntitlements = entitlements.filter { $0.source == .webCheckout }
            updateEntitlements(storeKitEnts + webEntitlements)
            ZSLogger.error("refreshEntitlementsAndPublish failed (backend): \(error) — republished local state", category: .entitlements)
        }
    }

    /// Refresh entitlements after a successful checkout.
    ///
    /// Delegates to `refreshEntitlementsAndPublish` for the canonical
    /// local-StoreKit + backend merge so upgrade / migration flows don't
    /// leave the UI on stale state (previously this method kept
    /// `self.entitlements.filter { .storeKit }` verbatim, which skipped the
    /// ownership filter and could duplicate rows that `getEntitlements` also
    /// returned from the backend).
    ///
    /// For consumables, the backend doesn't persist an entitlement, so if
    /// the fresh fetch doesn't contain one for this transaction, we append a
    /// local entitlement here so `newConsumableEntitlements(excluding:)` can
    /// match it and the app can credit tokens.
    internal func refreshEntitlementsAfterCheckout(transaction: CheckoutTransaction) async {
        guard let _ = backend else { return }

        // No userId means checkout without bootstrap — can't call the
        // backend, so all we can do is append the local fallback.
        guard storeKitManager?.currentUserId != nil else {
            appendLocalEntitlement(for: transaction)
            return
        }

        await refreshEntitlementsAndPublish()

        // Append a local fallback only when the server didn't return an
        // entitlement for this transaction (consumables, or a rare race
        // where the webhook hasn't landed yet).
        let txnId = transaction.id
        if !entitlements.contains(where: { $0.id == txnId || $0.id == "web_\(txnId)" }) {
            ZSLogger.info("Appended local entitlement for \(transaction.productId) — server did not include it (consumable or pre-webhook)", category: .entitlements)
            appendLocalEntitlement(for: transaction)
        }
    }

    /// Create and append a local entitlement from a transaction when backend fetch fails.
    private func appendLocalEntitlement(for transaction: CheckoutTransaction) {
        ZSLogger.info("Creating local fallback entitlement for \(transaction.productId) (transaction: \(transaction.id)). This entitlement is in-memory only — consumables are not persisted as backend EntitlementStates. restoreEntitlements() preserves it via EntitlementMerge until the host app credits it.", category: .entitlements)
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
    func storeKitDidSyncTransaction(productId: String, transactionId: UInt64, originalTransactionId: String?) {
        // Add to the owned set so the ownership filter includes this new purchase.
        // Without this, purchases made after bootstrap would be filtered out by
        // storeKitEntitlementsDidChange because their originalTransactionId wasn't
        // in the set built during bootstrap.
        if let origId = originalTransactionId {
            ownedStoreKitTransactionIds?.insert(origId)
        }
        delegate?.zeroSettleDidSyncStoreKitTransaction(
            productId: productId,
            transactionId: transactionId
        )
    }

    func storeKitSyncFailed(error: Error) {
        delegate?.zeroSettleStoreKitSyncFailed(error: error)
    }
}
