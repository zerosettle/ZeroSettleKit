//
//  ZeroSettle.swift
//  ZeroSettleKit
//
//  Main entry point for the ZeroSettle IAP SDK.
//  Provides web checkout for in-app purchases via Stripe.
//

import Foundation
import PassKit
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
public enum CheckoutFailureReason: Sendable {
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
    case checkoutFailed(reason: CheckoutFailureReason)

    /// Transaction verification failed after checkout.
    case transactionVerificationFailed(String)

    /// An API or network error occurred.
    case apiError(APIErrorDetail)

    /// The deferred-mode checkout config has expired (the server-side
    /// PENDING transaction's `checkout_config_expires_at` has passed). The SDK
    /// should re-initiate checkout via ``Backend/initiateCheckout(productId:userId:stripeCustomerId:storekitSubscriptionEnd:storekitOriginalTransactionId:checkoutMode:externalPurchaseToken:interactive:)``
    /// to get a fresh config rather than retrying
    /// ``Backend/finalizePaymentIntent(transactionId:)``.
    ///
    /// Maps to HTTP 410 from `POST /v1/iap/payment-intents/<id>/finalize/`.
    case checkoutConfigExpired

    /// The checkout callback URL could not be parsed.
    case invalidCallbackURL

    /// Web checkout is disabled for the user's jurisdiction.
    case webCheckoutDisabledForJurisdiction(Jurisdiction)

    /// No longer thrown. `purchase` / `purchaseViaStoreKit` now require an
    /// identified user unconditionally and throw ``userNotIdentified`` instead.
    /// Retained for binary/source compatibility; will be removed in ZeroSettleKit 2.0.
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

    /// A user-scoped method was called before ``ZeroSettle/identify(_:)``.
    /// Call `identify(.user(id:))` at app launch (after configure) before
    /// invoking user-scoped APIs like ``ZeroSettle/restoreEntitlements()``.
    case userNotIdentified

    /// The checkout never actually started — `create-payment-intent` did not
    /// return a transaction ID, so there is no Transaction record on the
    /// backend to verify, refund, or attribute. Distinct from `.cancelled`
    /// (user dismissed the sheet) and from `.checkoutFailed` (Stripe rejected
    /// the payment). The customer was NOT charged. Common causes: backend
    /// outage during PI creation, malformed request, server-side
    /// configuration error.
    case checkoutNotStarted

    /// Apple-Pay-only merchant configuration is active and the device
    /// cannot do Apple Pay at all (older hardware, simulator,
    /// MDM/parental restriction). The customer was NOT charged. The
    /// hosting app should show its own UX or skip the purchase path.
    ///
    /// This is a hard failure, not a cancellation —
    /// ``ZeroSettleError/isCancellation(_:)`` returns `false`. Retry-on-cancel
    /// handlers should treat it as a terminal error.
    case applePayUnavailable

    /// Apple-Pay-only merchant configuration is active and the device
    /// supports Apple Pay but Wallet has no supported cards. The customer
    /// was NOT charged.
    ///
    /// - Parameter autoPresentedSetup: Whether the SDK has already presented
    ///   the system Wallet setup sheet on the consumer's behalf. Determined
    ///   by ``Configuration/applePaySetupBehavior``:
    ///   - `true` when behavior is ``ApplePaySetupBehavior/presentBuiltInUI``
    ///     (the default). Wallet is opening; **do not surface additional UI
    ///     for this error and do not call ``ZeroSettle/presentApplePaySetup()``
    ///     again**. The accompanying `errorDescription` returns `nil` so
    ///     naive `error.localizedDescription` callers don't double-stack UI.
    ///   - `false` when behavior is ``ApplePaySetupBehavior/delegateToApp``.
    ///     The SDK has not opened Wallet; the consumer owns the setup UX
    ///     and should call ``ZeroSettle/presentApplePaySetup()`` (or its
    ///     own equivalent) when ready to proceed.
    ///
    /// This is a hard failure, not a cancellation —
    /// ``ZeroSettleError/isCancellation(_:)`` returns `false`.
    case applePaySetupRequired(autoPresentedSetup: Bool)

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
        case .checkoutConfigExpired:
            return "The checkout configuration has expired. Restart checkout to obtain a fresh session."
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
        case .userNotIdentified:
            return "ZeroSettle has not identified a user. Call ZeroSettle.shared.identify(.user(id:)) (or .anonymous) before invoking user-scoped APIs."
        case .checkoutNotStarted:
            return "Checkout never started. The PaymentIntent was not created — the customer was NOT charged. Likely a backend or configuration issue at PI-creation time; check Render logs for the `/v1/iap/payment-intents/` request that initiated this checkout."
        case .applePayUnavailable:
            return "Apple Pay is required for this purchase but is not available on this device."
        case .applePaySetupRequired(autoPresentedSetup: true):
            // SDK is presenting the Wallet setup sheet itself. Returning nil
            // means a naive `error.localizedDescription` call site shows
            // nothing — preventing competing UI on top of the system sheet.
            return nil
        case .applePaySetupRequired(autoPresentedSetup: false):
            return "Apple Pay is required for this purchase but no card is set up in Wallet."
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

// MARK: - Identity

/// The user identity passed to ``ZeroSettle/identify(_:)``.
///
/// ZeroSettleKit needs to know who is making purchases so it can attribute
/// StoreKit transactions, web checkouts, and entitlements to the right
/// account. `Identity` is the explicit, type-safe way to declare that —
/// covering the three states an app can be in at SDK init:
///
/// - **`.user(id:name:email:)`** — you have an authenticated user. The
///   common case. The SDK creates/updates a backend `Identity` for this
///   `id` and routes every subsequent API call against it.
/// - **`.anonymous`** — you have no authenticated user yet (or by design)
///   but want a stable identity for purchases. The SDK generates a UUID
///   on first call and persists it in `UserDefaults` under
///   `zerosettle.anonymous_session_uuid`. The same UUID is reused across
///   launches until ``ZeroSettle/logout()`` is called or the app is
///   uninstalled. Anonymous purchases attach to this UUID; they can be
///   reconciled into a real user account later via
///   `completeIdentification(.user(...))` (added in PR C2 — backend
///   reconciliation endpoint).
/// - **`.deferred`** — you intend to identify later (auth happens on a
///   subsequent screen). Suppresses the 10s "no user identified" warning
///   and is otherwise a no-op. Call ``ZeroSettle/identify(_:)`` again
///   with `.user(...)` or `.anonymous` once you know who the user is.
///
/// Pick exactly one. Don't mix `.user` with `.anonymous` in the same
/// session — that would create two backend `Identity` records for what
/// is logically the same person, defeating the point of the SDK.
public enum Identity: Sendable {
    /// An authenticated app user. `id` is your app's user identifier
    /// (any non-empty string — the SDK derives a UUIDv5 for
    /// `appAccountToken` internally). `name` and `email` are optional
    /// metadata stored on the Stripe Customer.
    case user(id: String, name: String? = nil, email: String? = nil)

    /// No authenticated user. The SDK generates and persists a stable
    /// session UUID. Suitable for apps that want to allow anonymous
    /// purchases.
    case anonymous

    /// Authentication is coming on a later screen. Suppresses the
    /// "no user identified" warning. Call ``ZeroSettle/identify(_:)``
    /// again with `.user(...)` or `.anonymous` once auth resolves.
    case deferred
}

// MARK: - Apple Pay Setup Behavior

/// How the SDK reacts when the merchant is Apple-Pay-only and the device's
/// Wallet has no supported card configured (`ApplePayAvailability.State.setupRequired`).
///
/// Set on ``ZeroSettle/Configuration/applePaySetupBehavior`` at SDK
/// configuration time.
public enum ApplePaySetupBehavior: Sendable {
    /// SDK opens the system Wallet setup flow automatically when the merchant
    /// is Apple-Pay-only and the device's Wallet has no supported card. The
    /// banner shows a built-in "Set up Apple Pay" CTA inline. Imperative entry
    /// points (``CheckoutSheet/present(from:product:userId:dismissible:checkoutURL:transactionId:onComplete:)``,
    /// `WebCheckoutFlow.beginCheckout`, `NativePay.Flow.pay`) **also** open
    /// Wallet, then surface
    /// ``ZeroSettleError/applePaySetupRequired(autoPresentedSetup:)`` with
    /// `autoPresentedSetup: true` so the caller knows the SDK already
    /// presented setup UI and shouldn't re-present its own. The error's
    /// `errorDescription` returns `nil` in this mode, so naive
    /// `error.localizedDescription` callers won't double-stack UI. Default.
    case presentBuiltInUI

    /// SDK delegates the setup flow to your app. The banner hides itself on
    /// `setupRequired`; all imperative entry points surface
    /// ``ZeroSettleError/applePaySetupRequired(autoPresentedSetup:)`` with
    /// `autoPresentedSetup: false` and **do not** open Wallet. Observe
    /// ``ZeroSettle/applePayAvailability`` to drive your own UI, then call
    /// ``ZeroSettle/presentApplePaySetup()`` (or your equivalent flow) when
    /// ready.
    case delegateToApp
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

        /// Whether to automatically preload checkout sessions for all products after ``ZeroSettle/identify(_:)``
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

        /// How the SDK reacts when the merchant is Apple-Pay-only and the
        /// device's Wallet has no supported card. Defaults to
        /// ``ApplePaySetupBehavior/presentBuiltInUI``.
        public let applePaySetupBehavior: ApplePaySetupBehavior

        public init(
            publishableKey: String,
            syncStoreKitTransactions: Bool = true,
            appleMerchantId: String? = nil,
            preloadCheckout: Bool = false,
            maxPreloadedWebViews: Int? = nil,
            applePaySetupBehavior: ApplePaySetupBehavior = .presentBuiltInUI
        ) {
            self.publishableKey = publishableKey
            self.syncStoreKitTransactions = syncStoreKitTransactions
            self.appleMerchantId = appleMerchantId
            self.preloadCheckout = preloadCheckout
            self.maxPreloadedWebViews = maxPreloadedWebViews
            self.applePaySetupBehavior = applePaySetupBehavior
        }

        internal var backendURL: URL {
            URL(string: "https://api.zerosettle.io/v1")!
        }
    }

    // MARK: - Observable State

    /// Whether the SDK has been configured.
    public private(set) var isConfigured: Bool = false

    /// Per-launch session identifier (new each process start; regenerated on
    /// `logout()`). Sent with on-screen offer impressions so the backend can
    /// dedup once per (user, session, variant). In-memory only — NOT persisted,
    /// unlike the anonymous-session UUID.
    public private(set) var sessionId: String = UUID().uuidString.lowercased()

    /// Regenerate the per-launch session id (called on logout so a new
    /// signed-in/guest session starts a fresh impression window).
    internal func regenerateSessionId() {
        sessionId = UUID().uuidString.lowercased()
    }

    /// The most-recently-resolved eligible offer for the active identified user,
    /// or nil if none is currently eligible. Used by the offer-impression APIs
    /// to auto-resolve what to report.
    public private(set) var currentOffer: ResolvedOffer?

    internal func setCurrentOffer(_ offer: ResolvedOffer?) { currentOffer = offer }

    #if DEBUG
    internal func setCurrentOfferForTesting(_ offer: ResolvedOffer?) { currentOffer = offer }
    #endif

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

    /// Debug / preview override for the SDK's effective jurisdiction.
    ///
    /// When non-nil, ``effectiveJurisdiction`` — and every jurisdiction-sensitive
    /// computed property (``checkoutType``, ``isWebCheckoutEnabled``, offer
    /// eligibility gates in ``ZSMigrationManager`` and ``ZSOfferManager``) —
    /// uses this value instead of the device's real ``detectedJurisdiction``.
    /// Set to `nil` to restore real detection.
    ///
    /// - Important: Debug / preview only. Gate assignments behind `#if DEBUG`.
    ///   There's no compile-time enforcement; the SDK trusts the integrator.
    /// - SeeAlso: ``effectiveJurisdiction``, ``detectedJurisdiction``
    public var forcedJurisdiction: Jurisdiction?

    /// The jurisdiction the SDK treats as current: ``forcedJurisdiction`` if set,
    /// otherwise ``detectedJurisdiction``, falling back to ``Jurisdiction/row``
    /// when Storefront detection hasn't yet populated.
    public var effectiveJurisdiction: Jurisdiction {
        forcedJurisdiction ?? detectedJurisdiction ?? .row
    }

    /// Whether ``identify(_:)`` has completed.
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
    /// Populated during ``identify(_:)`` so it's immediately available
    /// for building custom cancel flow UI without an extra network call.
    public private(set) var cancelFlowConfig: CancelFlow.Config?

    /// Migration manager for the StoreKit → web checkout migration flow.
    /// Access via ``migrationManager(for:)`` to guarantee a single shared instance.
    /// Starts in `.loading` and transitions after bootstrap completes.
    @available(*, deprecated, message: "Use offerManager(stripeCustomerId:) instead — call after identify(_:). ZSMigrationManager is itself class-level deprecated in favor of ZSOfferManager.")
    public private(set) var migrationManager: ZSMigrationManager?

    /// Unified offer manager for migration, storekit_to_web, and web_to_web flows.
    /// Access via ``offerManager(for:stripeCustomerId:)`` to guarantee a single shared instance.
    /// Starts in `.loading` and transitions after bootstrap completes.
    public private(set) var offerManager: ZSOfferManager?

    /// StoreKit purchases that another ZeroSettle account currently holds.
    ///
    /// Populated when sync detects cross-user OTID conflicts (backend returns
    /// `conflict: true, claim_available: true`). Consuming app observes via
    /// `@ObservedObject` / `@StateObject` and can render
    /// "transfer this purchase?" UX. Claim is opt-in via the existing
    /// `transferStoreKitOwnershipToCurrentUser(productId:)` API — SDK never
    /// auto-claims.
    public private(set) var pendingClaims: [PendingClaim] = []

    // MARK: - Customer Info

    /// Customer name included in all subsequent checkout requests.
    /// Set via ``identify(_:)`` or ``setCustomer(name:email:)``.
    /// Cleared by ``logout()``.
    public private(set) var customerName: String?

    /// Customer email included in all subsequent checkout requests.
    /// Set via ``identify(_:)`` or ``setCustomer(name:email:)``.
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
        let jurisdiction = effectiveJurisdiction
        if let override = config.jurisdictions[jurisdiction] {
            return override.sheetType
        }
        return config.sheetType
    }

    /// Whether web checkout is enabled for the detected jurisdiction.
    /// Checks jurisdiction override first, then falls back to the global setting.
    public var isWebCheckoutEnabled: Bool {
        guard let config = remoteConfig?.checkout else { return true }
        let jurisdiction = effectiveJurisdiction
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

    // MARK: - StoreKit appAccountToken

    /// Returns the deterministic UUID you should pass to Apple's
    /// `Product.purchase(options: [.appAccountToken(uuid)])` for the
    /// currently identified user.
    ///
    /// Use this **only** if you are calling `StoreKit.Product.purchase()`
    /// directly. If you call `ZeroSettle.shared.purchaseViaStoreKit(...)`,
    /// the SDK already sets the correct token for you — you don't need this.
    ///
    /// The token is computed via tenant-scoped UUIDv5 derivation:
    /// ```
    /// ROOT      = uuid5(NAMESPACE_DNS, "appaccounttoken.zerosettle.com")
    /// namespace = uuid5(ROOT, Bundle.main.bundleIdentifier)
    /// derived   = uuid5(namespace, currentUserId)
    /// ```
    /// The same algorithm runs server-side on every JWS sync, so the
    /// `appAccountToken` Apple signs into the JWS will match the syncing
    /// `user_id` and unlock cross-account ownership transfer (family
    /// sharing, cancel+rebuy, reinstall+resignin, sandbox OTID reuse).
    ///
    /// **Why this matters**: Apple's `appAccountToken` parameter requires
    /// a `UUID` value. Many developers identify users by non-UUID strings
    /// (Firebase UIDs, Privy IDs, Auth0 sub claims). Without this helper,
    /// a hand-rolled "format the user ID as a UUID" implementation will
    /// silently produce random or invalid UUIDs because `UUID(uuidString:)`
    /// rejects non-hex characters. Cross-account ownership transfer
    /// then fails for every user. Use this method instead.
    ///
    /// ```swift
    /// // Inside your purchase code:
    /// let token = try ZeroSettle.shared.recommendedAppAccountToken()
    /// let result = try await product.purchase(options: [.appAccountToken(token)])
    /// ```
    ///
    /// - Returns: The UUID to pass as `appAccountToken`. UUID-native user
    ///   IDs (e.g., RevenueCat-style) are passed through unchanged.
    /// - Throws: ``ZeroSettleError/userNotIdentified`` if `identify()` has
    ///   not been called yet.
    public func recommendedAppAccountToken() throws -> UUID {
        let userId = try requireIdentifiedUserId()
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        precondition(
            !bundleId.isEmpty,
            "Bundle.main.bundleIdentifier is nil — cannot derive appAccountToken"
        )
        return AppAccountToken.derive(userId: userId, bundleId: bundleId)
    }

    // MARK: - StoreKit Ownership Transfer

    /// **Destructive.** Transfer ownership of an Apple StoreKit subscription
    /// from whoever currently owns it on the backend to the currently
    /// identified user. Used to consolidate sub ownership when a user has
    /// purchased through Apple under one ZeroSettle account and now wants
    /// the entitlement attached to a different ZeroSettle account.
    ///
    /// **Use this only as a deliberate operations action.** Common cases:
    /// - **Testing**: switching between ZS test accounts on the same Apple sandbox ID.
    /// - **Account migration**: a user's sub was on account A, they now want it on account B.
    /// - **Customer support**: an agent is moving an entitlement on the user's behalf.
    ///
    /// **What it does**:
    /// 1. Locates the StoreKit transaction for `productId` on the device's current Apple ID.
    /// 2. POSTs the JWS to the backend's `/v1/iap/claim-entitlement/` endpoint.
    /// 3. The backend `TRANSFERRED_OUT`s the entitlement from its current
    ///    owner and `GRANTED`s it to the syncing user. Atomic on the backend.
    ///
    /// Only applicable to subscriptions and non-consumables. Consumables
    /// cannot be transferred (they're single-use).
    ///
    /// Requires ``identify(_:)`` to have been called.
    ///
    /// ```swift
    /// // After auth state changes:
    /// try await ZeroSettle.shared.identify(.user(id: newUser.id))
    /// try await ZeroSettle.shared.transferStoreKitOwnershipToCurrentUser(
    ///     productId: "com.myapp.premium.monthly"
    /// )
    /// ```
    ///
    /// - Parameter productId: The product whose ownership should move to the
    ///   currently identified user.
    /// - Throws: ``ZeroSettleError/productNotFound(_:)`` if the product has
    ///   no StoreKit transaction on this Apple ID;
    ///   ``ZeroSettleError/userNotIdentified`` if `identify()` has not been
    ///   called; or other ``ZeroSettleError`` cases for backend failures.
    @MainActor
    public func transferStoreKitOwnershipToCurrentUser(productId: String) async throws {
        let userId = try requireIdentifiedUserId()
        ZSLogger.info("[ZeroSettle] Initiating destructive StoreKit ownership transfer: product=\(productId) → userId=\(userId)", category: .entitlements)
        try await _claimEntitlementImpl(productId: productId, userId: userId)
    }

    /// Deprecated alias for ``transferStoreKitOwnershipToCurrentUser(productId:)``.
    /// The original name read as a passive lookup but the operation is a
    /// destructive ownership transfer; the name was changed to surface that.
    /// Same behavior; kept for source compat. Will be removed in 2.0.
    @MainActor
    @available(*, deprecated, renamed: "transferStoreKitOwnershipToCurrentUser(productId:)", message: "Renamed for clarity — claimEntitlement is a destructive ownership transfer, not a lookup. Use transferStoreKitOwnershipToCurrentUser(productId:). Will be removed in ZeroSettleKit 2.0.")
    public func claimEntitlement(productId: String) async throws {
        let userId = try requireIdentifiedUserId()
        try await _claimEntitlementImpl(productId: productId, userId: userId)
    }

    /// Deprecated. Use ``transferStoreKitOwnershipToCurrentUser(productId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "transferStoreKitOwnershipToCurrentUser(productId:)", message: "Call identify(.user(id:)) once, then transferStoreKitOwnershipToCurrentUser(productId:). Will be removed in ZeroSettleKit 2.0.")
    public func claimEntitlement(productId: String, userId: String) async throws {
        setActiveUserId(userId)
        try await _claimEntitlementImpl(productId: productId, userId: userId)
    }

    internal func _claimEntitlementImpl(productId: String, userId: String) async throws {
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
        _ = try await _restoreEntitlementsImpl(userId: userId)

        // Clear the pending claim so any view bound to pendingClaims stops
        // showing the "transfer this purchase?" prompt after the user accepts.
        if response.claimed == true {
            removePendingClaim(productId: productId)
        }
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
    /// For initial setup, prefer passing `name`/`email` to ``identify(_:)``.
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

    /// Clears all user-scoped state, resetting the SDK to pre-identify condition.
    ///
    /// Call this when the current user logs out of your app. After `logout()`,
    /// the SDK is still configured — call ``identify(_:)`` for
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

        // Pending claims — clear so the prior user's "transfer this purchase?"
        // hint is not visible to the next user (privacy + UX).
        objectWillChange.send()
        pendingClaims = []

        // Cached checkout sessions (PaymentIntents for previous user)
        Task { await CheckoutResponseCache.shared.clearAll() }

        // Preloaded WebViews hold a client_secret for the previous user —
        // present one and you attribute the purchase to whoever that PI
        // was created for. Tear them all down so a fresh account starts
        // with no carry-over state.
        CheckoutPreloaderPool.shared.resetAll()

        // StoreKit listener userId + identified-user state
        setActiveUserId(nil)

        // Anonymous session UUID — clearing on logout means the next
        // identify(.anonymous) generates a fresh UUID. This is correct
        // for shared-device flows: user A logs out, user B taps "Continue
        // as guest" and gets their own anonymous identity rather than
        // inheriting A's. The invariant "same UUID across launches" is
        // scoped to a session, not an install.
        UserDefaults.standard.removeObject(forKey: Self.anonymousSessionUUIDKey)
        regenerateSessionId()
        currentOffer = nil

        // Deferred-identification flag — logout means we no longer have
        // an explicit "auth coming later" assertion. The next configure()
        // / identify() cycle is responsible for re-declaring intent.
        deferredIdentification = false

        // Persistent sync queue (StoreKitSyncQueue) holds JWS-tokens keyed
        // by the previous user's id. If we don't drop them, the next
        // launch's retryAll() would replay them under the wrong user —
        // attributing the previous user's purchases to whoever's signed
        // in next. The transactions remain unfinished in StoreKit and
        // will be redelivered when the next user identifies.
        if let storeKitManager {
            Task { await storeKitManager.clearSyncQueue() }
        }
    }

    // MARK: - Delegate

    /// Delegate to receive IAP event callbacks.
    @ObservationIgnored
    public weak var delegate: ZeroSettleDelegate?

    // MARK: - Apple Pay Availability

    /// Single shared `ApplePayAvailability` instance. Initialized eagerly
    /// when the `ZeroSettle.shared` singleton is first touched (e.g., by
    /// `configure()`) — apps that never read this property still pay the
    /// init cost, which is two `NotificationCenter.addObserver` calls and
    /// one `PKPaymentAuthorizationController.canMakePayments()`. Negligible.
    public let applePayAvailability = ApplePayAvailability()

    /// Launches the system Wallet setup flow so the user can add a card
    /// for Apple Pay. The SDK does not wait for completion — the
    /// `applePayAvailability` service auto-refreshes on
    /// `PKPassLibraryDidChange` and `UIApplication.didBecomeActive`,
    /// so observed state will flip to `.ready` once the user finishes.
    ///
    /// Call from a `.applePaySetupRequired` error handler, or from a
    /// banner CTA when ``ApplePayAvailability/State/setupRequired`` is observed.
    public func presentApplePaySetup() {
        PKPassLibrary().openPaymentSetup()
    }

    /// Whether the SDK is currently treating this merchant as Apple-Pay-only.
    /// Drives banner CTA swap and the imperative-checkout pre-flight gate.
    ///
    /// Reads the live backend `remoteConfig.checkout.paymentMethods`. In
    /// DEBUG builds, setting ``ApplePayAvailability/debugStateOverride``
    /// also forces this to `true` so the banner / gate code paths can be
    /// exercised against tenants that aren't actually Apple-Pay-only on
    /// the backend.
    public var isApplePayOnly: Bool {
        #if DEBUG
        if applePayAvailability.debugStateOverride != nil { return true }
        #endif
        return remoteConfig?.checkout.isApplePayOnly == true
    }

    /// The dev's chosen ``ApplePaySetupBehavior``, with the public default
    /// (`.presentBuiltInUI`) substituted when the SDK is unconfigured. Read
    /// by the ``ApplePayPreflightGate`` call sites and the banner views to
    /// keep the fallback definition in one place.
    internal var resolvedApplePaySetupBehavior: ApplePaySetupBehavior {
        currentConfig?.applePaySetupBehavior ?? .presentBuiltInUI
    }

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

    /// Build a ``Backend`` bound to the current configuration.
    ///
    /// Throws ``ZeroSettleError/notConfigured`` if the SDK has not been
    /// configured or has no resolvable base URL. Callers that want a specific
    /// log prefix can catch and re-log; the generic failure is logged here.
    internal func makeBackend() throws -> Backend {
        guard let config = currentConfig, let baseURL = effectiveBaseURL else {
            ZSLogger.error("makeBackend() failed — SDK not configured", category: .migration)
            throw ZeroSettleError.notConfigured
        }
        return Backend(baseURL: baseURL, publishableKey: config.publishableKey)
    }

    // MARK: - Private Helpers

    /// Single source of truth for setting the active user. Updates internal
    /// ``currentUserId`` and propagates to ``StoreKitManager`` so the
    /// `Transaction.updates` listener can sync incoming purchases.
    ///
    /// All public methods that accept a `userId` must route through this
    /// helper. Adding a new userId-accepting public API without calling this
    /// will silently break StoreKit sync — see `lqwTc...` postmortem
    /// (2026-04-28) for the canonical incident.
    ///
    /// Pass `nil` to clear (logout path).
    internal func setActiveUserId(_ userId: String?) {
        currentUserId = userId
        // Start the StoreKit `Transaction.updates` listener on the first
        // non-nil userId after configure(). This eliminates the race where
        // Apple redelivered an unfinished transaction in the
        // [configure → identify] window and `handleVerifiedTransaction`
        // ran with `userId == nil` — the canonical 1.3.x StoreKit-attribution
        // bug class. Subsequent calls (re-identify, user switch) just update
        // the userId on the running listener.
        if let userId, !userId.isEmpty,
           let manager = storeKitManager, !manager.isListening {
            manager.startListening(userId: userId)
        } else {
            storeKitManager?.setUserId(userId)
        }
    }

    /// `UserDefaults` key under which the anonymous session UUID is
    /// persisted. Stable across app launches; cleared by ``logout()``.
    /// Namespaced to ZeroSettleKit so it does not collide with whatever
    /// the app stores under the same key.
    private static let anonymousSessionUUIDKey = "zerosettle.anonymous_session_uuid"

    /// Returns the persisted anonymous session UUID, generating and
    /// persisting one if none exists. Used by ``identify(_:)`` when
    /// passed ``Identity/anonymous``.
    ///
    /// We persist in `UserDefaults` (not Keychain) because anonymous
    /// session continuity is not a security boundary — losing it just
    /// means the user gets a new anonymous identity, which is fine. The
    /// invariant is "same UUID across launches until ``logout()``"; that
    /// holds in `UserDefaults`, and avoids the cross-process / iCloud
    /// surprises Keychain brings.
    private func anonymousSessionUserId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.anonymousSessionUUIDKey),
           !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Self.anonymousSessionUUIDKey)
        ZSLogger.info(
            "[ZeroSettle] Generated new anonymous session UUID. Persisted to UserDefaults; cleared on logout().",
            category: .general
        )
        return fresh
    }

    /// Returns the currently identified userId, throwing
    /// ``ZeroSettleError/userNotIdentified`` if ``identify(_:)``
    /// has not been called. Used by the userId-less public methods added in
    /// 1.2.4 as the canonical replacement for the deprecated explicit-userId
    /// overloads slated for removal in 2.0.
    private func requireIdentifiedUserId() throws -> String {
        guard let userId = currentUserId,
              !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ZSLogger.error(
                "ZeroSettleKit: a user-scoped method was called without an identified user. " +
                "Call ZeroSettle.shared.identify(.user(id:)) (or .anonymous) before invoking user-scoped APIs.",
                category: .general
            )
            throw ZeroSettleError.userNotIdentified
        }
        return userId
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

    /// Add a pending claim if not already present (matched by productId + OTID).
    /// Internal — populated by StoreKitManager when sync detects a cross-user conflict.
    internal func addPendingClaim(_ claim: PendingClaim) {
        if pendingClaims.contains(claim) { return }
        objectWillChange.send()
        pendingClaims.append(claim)
    }

    /// Remove pending claims for a productId. Internal — called when claim
    /// completes successfully or when the consuming app dismisses the prompt.
    internal func removePendingClaim(productId: String) {
        let filtered = pendingClaims.filter { $0.productId != productId }
        if filtered.count == pendingClaims.count { return }
        objectWillChange.send()
        pendingClaims = filtered
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

    /// Handle to the deferred "no user identified after configure()" warning
    /// task. Cancelled when ``configure(_:)`` is called again so the warning
    /// doesn't fire spuriously against the new configuration.
    @ObservationIgnored
    private var configureWarningTask: Task<Void, Never>?

    /// True when the app explicitly called ``identify(_:)`` with
    /// ``Identity/deferred``, signalling that auth resolves on a later
    /// screen. Suppresses the 10s no-user warning. Cleared on a subsequent
    /// ``identify(_:)`` with `.user` or `.anonymous`, or on ``logout()``.
    /// Exposed `internal private(set)` so the test target can pin the
    /// invariant that `.user`/`.anonymous` clear it.
    @ObservationIgnored
    internal private(set) var deferredIdentification: Bool = false

    /// The currently identified user, set by ``identify(_:)``
    /// (any case other than ``Identity/deferred``). Cleared by ``logout()``.
    /// Read-only externally — mutate via ``setActiveUserId(_:)`` to keep
    /// ``StoreKitManager`` in sync.
    @ObservationIgnored
    internal private(set) var currentUserId: String?

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
    /// StoreKit listener). It does **not** identify the user, fetch products, or
    /// restore entitlements — call ``identify(_:)`` next to do all three:
    ///
    /// ```swift
    /// // 1. Configure (typically in App.init or AppDelegate)
    /// ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_live_..."))
    ///
    /// // 2. Identify — fetches catalog, restores entitlements, syncs StoreKit
    /// let catalog = try await ZeroSettle.shared.identify(.user(
    ///     id: currentUser.id,
    ///     name: currentUser.name,
    ///     email: currentUser.email
    /// ))
    /// ```
    ///
    /// For apps without authenticated users, pass ``Identity/anonymous`` to
    /// generate a stable per-install UUID. Use ``Identity/deferred`` if auth
    /// resolves on a later screen.
    ///
    /// - Parameter config: The IAP configuration with your publishable key
    public func configure(_ config: Configuration) {
        // Clear cached checkout URLs from the previous environment to prevent
        // stale sandbox PIs being served after switching to live (or vice versa).
        Task { await CheckoutResponseCache.shared.clearAll() }

        // Tear down any previous configuration cleanly. configure() can be
        // called more than once (debug environment toggles, key rotation,
        // multi-tenant testing). Without this, the previous StoreKitManager's
        // Transaction.updates listener keeps running with a stale Backend +
        // userId, doubling sync attempts and binding new transactions to the
        // wrong publishable key.
        if let previousManager = self.storeKitManager {
            previousManager.stopListening()
            self.storeKitManager = nil
        }
        // Cancel the previous deferred-warning task so the warning doesn't
        // fire spuriously later under the new configuration.
        configureWarningTask?.cancel()
        configureWarningTask = nil
        // Tear down preloaded WebViews tied to the previous publishable key —
        // they hold client_secrets from the previous environment.
        CheckoutPreloaderPool.shared.resetAll()

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
            // Deliberately NOT calling `startListening()` here. The
            // `Transaction.updates` listener kicks off in `setActiveUserId(_:)`
            // on the first non-nil userId, so Apple's redelivered unfinished
            // transactions can never reach `handleVerifiedTransaction` while
            // `userId == nil`. Apps that never call `identify(...)` will see
            // their unfinished transactions queue at the StoreKit layer; the
            // 10-second post-configure deferred warning + the existing
            // `handleVerifiedTransaction` error log surface this loudly.
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

        // Warn if no user is identified within ~10s of configure(). Without
        // identification, StoreKit purchases that arrive via Transaction.updates
        // can't be attributed to a user and will be left unfinished. See the
        // lqwTc... postmortem (2026-04-28) for the canonical incident. The
        // task handle is stored so a subsequent configure() call can cancel
        // it (above) — otherwise rapid reconfigure cycles accumulate Tasks
        // that fire spurious warnings against the new state.
        //
        // The warning is suppressed if the app has explicitly declared
        // ``Identity/deferred`` — that's the supported "auth comes later"
        // path. Apps with anonymous-launch flows should call
        // ``identify(.anonymous)``; that also clears the warning condition.
        configureWarningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            guard let self else { return }
            guard !Task.isCancelled else { return }
            if self.currentUserId == nil && !self.deferredIdentification {
                ZSLogger.error(
                    "ZeroSettleKit: configure() was called 10s ago but no Identity has been declared yet. " +
                    "StoreKit purchases will NOT sync to the backend until you call ZeroSettle.shared.identify(.user(id:)) " +
                    "(or .anonymous, or .deferred to suppress this warning). See the Identity enum docs for details.",
                    category: .general
                )
            }
        }
    }

    // MARK: - Identify (canonical user setup)

    /// Identify the current user **and** perform full SDK bootstrap.
    ///
    /// **Canonical entry point as of SDK 1.2.4.** Despite the name, this
    /// does more than just record an identity — for ``Identity/user(id:name:email:)``
    /// and ``Identity/anonymous`` it also fetches the product catalog,
    /// restores entitlements, and starts the StoreKit transaction listener.
    /// You do **not** need to call ``fetchProducts(userId:)`` or
    /// ``restoreEntitlements()`` separately on launch.
    ///
    /// `Identity` is an enum so the SDK can distinguish between three
    /// states an app can be in at init: an authenticated user
    /// (``Identity/user(id:name:email:)``), an anonymous session
    /// (``Identity/anonymous``), or "auth comes later"
    /// (``Identity/deferred``). The SDK can't infer this from a missing
    /// argument — the difference between "I have no user yet" and "I have
    /// no auth and never will" matters for purchase attribution and for
    /// the no-user warning.
    ///
    /// ```swift
    /// // At app launch
    /// ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_live_..."))
    ///
    /// // ① Authenticated user (the common case)
    /// try await ZeroSettle.shared.identify(.user(
    ///     id: currentUser.id,
    ///     name: "Jane Doe",
    ///     email: "jane@example.com"
    /// ))
    ///
    /// // ② No auth — generate a stable session UUID
    /// try await ZeroSettle.shared.identify(.anonymous)
    ///
    /// // ③ Auth comes later — suppress the warning
    /// try await ZeroSettle.shared.identify(.deferred)
    /// ```
    ///
    /// **Sequencing**: call this after ``configure(_:)`` and before any
    /// user-scoped API. The SDK does not require you to identify before
    /// configuring, but most user-scoped APIs throw
    /// ``ZeroSettleError/userNotIdentified`` if no `Identity` has been
    /// declared. ``Identity/deferred`` is the explicit "I'll call again
    /// later" — it doesn't satisfy `userNotIdentified` checks.
    ///
    /// **State semantics**:
    /// - `.user(id:)` — sets ``currentUserId`` to the provided id, runs
    ///   the full bootstrap flow (StoreKit sync, product fetch,
    ///   entitlement restore, Stripe customer create/update), returns
    ///   the catalog.
    /// - `.anonymous` — generates a UUID on first call and persists it
    ///   in `UserDefaults`. Subsequent `.anonymous` calls reuse the same
    ///   UUID. Runs the same bootstrap flow against that UUID. Cleared
    ///   by ``logout()`` (next `.anonymous` generates a fresh UUID).
    /// - `.deferred` — sets a flag that suppresses the 10s no-user
    ///   warning, otherwise a no-op. Returns `nil`.
    ///
    /// - Parameter identity: The user identity declaration.
    /// - Returns: The product catalog for `.user`/`.anonymous`; `nil`
    ///   for `.deferred`.
    @discardableResult
    public func identify(_ identity: Identity) async throws -> ProductCatalog? {
        switch identity {
        case .user(let id, let name, let email):
            deferredIdentification = false
            return try await _runIdentify(userId: id, name: name, email: email)
        case .anonymous:
            deferredIdentification = false
            let userId = anonymousSessionUserId()
            return try await _runIdentify(userId: userId, name: nil, email: nil)
        case .deferred:
            deferredIdentification = true
            ZSLogger.info(
                "[ZeroSettle] identify(.deferred) — suppressing no-user warning. Call identify(.user(...)) or identify(.anonymous) when auth resolves.",
                category: .general
            )
            return nil
        }
    }

    /// Deprecated alias for ``identify(_:)`` with ``Identity/user(id:name:email:)``.
    /// Same behavior, kept for source compatibility with SDK 1.x integrations.
    /// Will be removed in 2.0.
    @available(*, deprecated, message: "Use identify(.user(id: ..., name: ..., email: ...)) instead. bootstrap() will be removed in ZeroSettleKit 2.0.")
    @discardableResult
    public func bootstrap(userId: String, name: String? = nil, email: String? = nil) async throws -> ProductCatalog {
        deferredIdentification = false
        return try await _runIdentify(userId: userId, name: name, email: email)
    }

    /// Tracks an in-flight identify so concurrent calls for the same userId
    /// share a single network round-trip. SwiftUI's `.task(id:)` can fire its
    /// body more than once during cold-launch scene-phase transitions (even
    /// when the id value is unchanged), and without single-flighting, the
    /// first call's URLSession data tasks get cooperatively cancelled
    /// (NSURLError -999) when SwiftUI cancels the first task body's parent.
    @ObservationIgnored
    private var inFlightBootstrap: (userId: String, task: Task<ProductCatalog, Error>)?

    private func _runIdentify(userId: String, name: String?, email: String?) async throws -> ProductCatalog {
        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ZSLogger.error("identify() called with empty userId — this is a no-op. Pass a valid user identifier.", category: .entitlements)
            throw ZeroSettleError.invalidUserId
        }

        // Single-flight: if a bootstrap for the SAME userId is already running,
        // join it instead of starting a parallel call. The in-flight Task is
        // unstructured (`Task { ... }`) so it survives this caller's parent
        // being cancelled — both callers end up with the same result.
        if let inFlight = inFlightBootstrap, inFlight.userId == userId {
            return try await inFlight.task.value
        }

        // Concurrent identify with a DIFFERENT userId: cancel the previous
        // in-flight bootstrap before starting the new one. Without this, two
        // concurrent identify(A) / identify(B) calls would both run to
        // completion and the LATER-finishing one would clobber state set by
        // the earlier one (currentUserId, customerName, entitlements,
        // ownedStoreKitTransactionIds, the StoreKit listener's userId).
        // This caused wrong-user attribution in apps with fast account-switch
        // flows. Cancelling here means the loser's await throws CancellationError
        // and the winner (this call) holds the canonical state.
        if let inFlight = inFlightBootstrap {
            ZSLogger.info(
                "identify(.user(id: \(userId))) cancelled in-flight identify(.user(id: \(inFlight.userId))) — newer wins",
                category: .general
            )
            inFlight.task.cancel()
            inFlightBootstrap = nil
        }

        // Detached-style unstructured Task (`Task { @MainActor in ... }`) so
        // SwiftUI's parent-Task cancellation does NOT propagate and tear down
        // our in-flight URLSession requests. Clear the in-flight reference
        // INSIDE the Task body — clearing in the outer caller's frame would
        // race with caller cancellation and leave the second call to start a
        // new bootstrap on top of the still-running one.
        let task = Task<ProductCatalog, Error> { @MainActor in
            defer { self.inFlightBootstrap = nil }
            return try await self._runBootstrap(userId: userId, name: name, email: email)
        }
        inFlightBootstrap = (userId, task)
        return try await task.value
    }

    private func _runBootstrap(userId: String, name: String?, email: String?) async throws -> ProductCatalog {
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
        // `migrationManager` is unconditionally torn down. ZSMigrationManager
        // is class-level deprecated in favor of ZSOfferManager and has no
        // in-place identity-promotion path; the orphan window for any view
        // wired to a dormant migration manager is bounded by the deprecation
        // and not worth additional surface area to fix.
        migrationManager = nil
        // For `offerManager`: only tear down on a genuine user switch. If the
        // cached manager is dormant (empty userId — created via
        // `offerManager()` pre-identify) or already pinned to this same user
        // (re-identify), keep it. `_getOrCreateOfferManager` below will then
        // promote the dormant case in place via `setActiveUserId(_:)`,
        // keeping any consuming `@ObservedObject` reference live instead of
        // orphaning it.
        if let existing = offerManager, !existing.userId.isEmpty, existing.userId != userId {
            offerManager = nil
        }
        ownedStoreKitTransactionIds = nil
        Task { await CheckoutResponseCache.shared.clearAll() }
        // Tear down preloaded WebViews — they hold a client_secret from
        // the previous user's PI. See logout() for rationale.
        CheckoutPreloaderPool.shared.resetAll()

        // Store customer info for subsequent checkout requests.
        self.customerName = name
        self.customerEmail = email

        // 1. Sync StoreKit transactions to the backend so the Identity and
        //    Entitlement records exist before we check migration eligibility.
        setActiveUserId(userId)
        if let storeKitManager {
            ownedStoreKitTransactionIds = await storeKitManager.syncCurrentTransactions(userId: userId)
        }

        // 2. Fetch products, cancel flow config, and restore entitlements in parallel.
        //    Products can now check migration eligibility because the Identity
        //    was created by the sync above.
        async let catalogTask = fetchProducts(userId: userId)
        async let cancelFlowTask: Void = loadCancelFlowConfig(userId: userId)
        async let _entitlementsTask: Void = {
            try await self._restoreEntitlementsImpl(userId: userId)
        }()

        let catalog = try await catalogTask
        await cancelFlowTask
        _ = try await _entitlementsTask

        isBootstrapped = true

        // 4. Ensure migration manager exists. If the view already created one
        //    (via migrationManager(...)), reuse it — Combine will re-evaluate
        //    now that isBootstrapped is true. Otherwise create one with full data.
        _ = _getOrCreateMigrationManager(userId: userId, stripeCustomerId: nil)

        // 5. Ensure unified offer manager exists alongside migration manager.
        _ = _getOrCreateOfferManager(userId: userId, stripeCustomerId: nil)

        // 6. Pre-create PaymentIntents so the first checkout opens instantly.
        if currentConfig?.preloadCheckout != false {
            Task { await CheckoutSheet<EmptyView>.warmUpAll(userId: userId) }
        }

        return catalog
    }

    // MARK: - Migration Manager

    /// Returns the shared migration manager, creating one if it doesn't exist yet.
    ///
    /// Both ``MigrationTipView`` and ``identify(_:)`` call this to guarantee
    /// a single shared instance. The manager starts in `.loading` and transitions
    /// to `.eligible` or `.ineligible` once bootstrap completes (via Combine).
    ///
    /// - Parameters:
    ///   - userId: Your app's user identifier
    ///   - stripeCustomerId: Optional existing Stripe Customer ID (`cus_xxx`)
    ///     to attach the checkout to.
    /// - Returns: The shared ``ZSMigrationManager``
    /// Returns the shared ``ZSMigrationManager`` for the currently identified
    /// user, creating one if it doesn't exist yet. Requires
    /// ``identify(_:)`` to have been called.
    @discardableResult
    public func migrationManager(stripeCustomerId: String? = nil) throws -> ZSMigrationManager {
        let userId = try requireIdentifiedUserId()
        return _getOrCreateMigrationManager(userId: userId, stripeCustomerId: stripeCustomerId)
    }

    /// Deprecated. Use ``migrationManager(stripeCustomerId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "migrationManager(stripeCustomerId:)", message: "Call identify(.user(id:)) once, then migrationManager(stripeCustomerId:) without userId. Will be removed in ZeroSettleKit 2.0.")
    @discardableResult
    public func migrationManager(for userId: String, stripeCustomerId: String? = nil) -> ZSMigrationManager {
        setActiveUserId(userId)
        return _getOrCreateMigrationManager(userId: userId, stripeCustomerId: stripeCustomerId)
    }

    internal func _getOrCreateMigrationManager(userId: String, stripeCustomerId: String?) -> ZSMigrationManager {
        if let existing = migrationManager { return existing }
        let manager = ZSMigrationManager(userId: userId, stripeCustomerId: stripeCustomerId)
        migrationManager = manager
        return manager
    }

    // MARK: - Offer Manager

    /// Returns the shared ``ZSOfferManager``, creating one if it doesn't exist yet.
    ///
    /// **Eager and non-throwing** — safe to call before ``identify(_:)``. If
    /// identify hasn't run, the returned manager starts in
    /// ``Offer/State/loading`` with an empty userId; the SDK promotes it
    /// in place by calling its internal `setActiveUserId(_:)` as soon as
    /// `identify(_:)` completes. Consumers holding the manager via
    /// `@ObservedObject` see state changes naturally.
    ///
    /// - Parameter stripeCustomerId: Optional existing Stripe Customer ID
    ///   (`cus_xxx`) to attach the checkout to.
    /// - Returns: The shared ``ZSOfferManager``.
    @discardableResult
    public func offerManager(stripeCustomerId: String? = nil) -> ZSOfferManager {
        // Empty userId is the documented "dormant" placeholder; promoted
        // by `_runIdentify` via `setActiveUserId(_:)` when identify runs.
        let userId = currentUserId ?? ""
        return _getOrCreateOfferManager(userId: userId, stripeCustomerId: stripeCustomerId)
    }

    /// Deprecated. Use ``offerManager(stripeCustomerId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "offerManager(stripeCustomerId:)", message: "Call identify(.user(id:)) once, then offerManager(stripeCustomerId:) without userId. Will be removed in ZeroSettleKit 2.0.")
    @discardableResult
    public func offerManager(for userId: String, stripeCustomerId: String? = nil) -> ZSOfferManager {
        setActiveUserId(userId)
        return _getOrCreateOfferManager(userId: userId, stripeCustomerId: stripeCustomerId)
    }

    internal func _getOrCreateOfferManager(userId: String, stripeCustomerId: String?) -> ZSOfferManager {
        // Promote any existing manager rather than orphaning it. This is the
        // path that fires when `offerManager()` was called pre-identify
        // (creating a dormant manager with an empty userId) and `identify(_:)`
        // later resolves: `_runIdentify` calls back here with the real userId,
        // and we mutate the cached manager in place instead of returning a
        // stale instance or creating a parallel one.
        if let existing = offerManager {
            existing.setActiveUserId(userId)
            return existing
        }
        let manager = ZSOfferManager(activeUserId: userId, stripeCustomerId: stripeCustomerId)
        offerManager = manager
        return manager
    }

    /// Non-instantiating peek at the active OfferManager. Returns `nil` if no
    /// manager has been created this session. Used by `OfferCheckoutBookkeeping`
    /// to detect active offer context inside the standard purchase entry points
    /// without inadvertently creating a manager for adopters who don't use
    /// offers at all.
    internal var _activeOfferManagerForBookkeeping: ZSOfferManager? {
        return offerManager
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

        // Propagate to internal state + StoreKitManager so the
        // Transaction.updates listener can sync subsequent purchases. Prior
        // to 1.2.4 this was missing, causing StoreKit transactions to be
        // silently dropped for devs who only ever called fetchProducts(userId:)
        // without bootstrap(). See lqwTc... postmortem (2026-04-28).
        if let userId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setActiveUserId(userId)
        }

        // Fall back to the identified user when caller passes no userId. This
        // is what makes `fetchProducts()` (no args) work seamlessly after
        // identify() — it returns a user-context catalog (with migration/offer
        // config) instead of the anonymous catalog.
        let effectiveUserId = userId ?? currentUserId

        do {
            // 1. Fetch from ZeroSettle backend (includes config when userId is provided)
            let catalog = try await backend.fetchProducts(userId: effectiveUserId)
            var products = catalog.products

            if let config = catalog.config {
                remoteConfig = config
            }

            // Detect jurisdiction from App Store storefront
            await detectJurisdiction()

            // 2. Try to fetch ALL products from StoreKit, keyed by each product's
            //    StoreKit SKU (storeKitProductId, falling back to the canonical id).
            let allProductIds = products.map { $0.effectiveStoreKitId }

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
                    if let skProduct = skProducts[products[i].effectiveStoreKitId] {
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
    /// is dismissed. For the WebView type, checkout is hosted in an in-app sheet — the same
    /// `CheckoutSheet` used by `presentPaymentSheet` and the `.checkoutSheet` modifier — which
    /// preloads and reports completion directly; no universal link or backend polling is involved.
    ///
    /// - Important: An identified user is **required**. Call ``ZeroSettle/identify(_:)``
    ///   with `.user(id:)` or `.anonymous` before purchasing — this method throws
    ///   ``ZeroSettleError/userNotIdentified`` otherwise. `.deferred` does not count
    ///   as identified.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: (Deprecated) Explicit app user identifier. Prefer calling
    ///     ``ZeroSettle/identify(_:)`` once, then `purchase` without `userId`.
    ///     Will be removed in ZeroSettleKit 2.0.
    /// - Returns: The verified ``CheckoutTransaction`` on success
    @discardableResult
    public func purchase(
        productId: String,
        userId: String? = nil,
        presentation: CheckoutType? = nil
    ) async throws -> CheckoutTransaction {
        guard let checkoutFlow, let backend else {
            throw ZeroSettleError.notConfigured
        }

        // Warn if the universal link handler isn't installed
#if DEBUG
        if !handlerInstalled {
            ZSLogger.error(".zeroSettleHandler() is not installed on any view. Universal link callbacks from Safari checkout will not be received. Add .zeroSettleHandler() to your root view.", category: .checkout)
        }
#endif

        // Purchases require an identified user. Honor an explicitly passed
        // (deprecated) userId; otherwise resolve the user set via identify(_:).
        // Throws userNotIdentified when neither is present.
        let effectiveUserId = try userId ?? requireIdentifiedUserId()

        // Per-user routing directive from the backend. `checkout_route` is
        // ORTHOGONAL to `web_price`: a StoreKit-only product (no Stripe mapping)
        // returns `checkout_route == .web` WITH `web_price == nil`, and a
        // `checkout_routing` experiment can route a cohort OFF web checkout with
        // `checkout_route == .store`. In both cases attempting web checkout
        // would fail (a 403 for the disabled cohort, or no price to charge), so
        // the rule is: use WEB only when `checkout_route == .web` AND a web
        // price exists; otherwise route to native StoreKit and return a
        // CheckoutTransaction synthesized from the StoreKit result. Checked
        // BEFORE the `isWebCheckoutEnabled` gate so a store-routed user in a
        // web-disabled jurisdiction still gets StoreKit rather than the thrown
        // jurisdiction error.
        if let routedProduct = product(for: productId), routedProduct.routesToStoreKit {
            ZSLogger.info("Checkout routing: product=\(productId) routed to StoreKit (checkout_route=\(routedProduct.checkoutRoute.rawValue), webPrice=\(routedProduct.webPrice == nil ? "nil" : "set"), storeKitAvailable=\(routedProduct.storeKitAvailable))", category: .checkout)
            return try await purchaseRoutedToStoreKit(productId: productId, userId: effectiveUserId)
        }

        // Per-call override (e.g. server-driven `Offer.checkoutPresentation`)
        // beats the global setting. Falls back to the global type when nil.
        let effectiveType = presentation ?? checkoutType
        ZSLogger.info("Checkout routing: product=\(productId), jurisdiction=\(effectiveJurisdiction.rawValue), checkoutType=\(effectiveType.rawValue), webCheckoutEnabled=\(isWebCheckoutEnabled)", category: .checkout)

        // Check if web checkout is enabled for the detected jurisdiction
        if !isWebCheckoutEnabled {
            ZSLogger.error("Web checkout disabled for \(effectiveJurisdiction.rawValue) jurisdiction. The SDK will throw webCheckoutDisabledForJurisdiction. Configure this in your ZeroSettle dashboard under Checkout Configuration.", category: .checkout)
            throw ZeroSettleError.webCheckoutDisabledForJurisdiction(effectiveJurisdiction)
        }

        // Auto-bookkeeping: arm the offer state machine if this purchase is
        // offer-bound. Idempotent — no-op for non-offer products.
        armOfferForCheckoutIfApplicable(productId: productId)

        // Update StoreKit manager with user ID for future sync operations
        setActiveUserId(effectiveUserId)

        // WebView checkout renders inside a hosted WKWebView sheet — it cannot
        // be handed off to a browser the way .safari/.safariVC are. Route it to
        // the same CheckoutSheet UIKit bridge that `presentPaymentSheet` and the
        // `.checkoutSheet` modifier use. CheckoutSheet creates its own
        // inline-mode session and owns Apple Pay preflight, offer
        // arming/completion, entitlement refresh, and the
        // `zeroSettleCheckoutDidComplete` delegate call — so this branch returns
        // before the browser-oriented flow below rather than duplicating it.
        if effectiveType == .webView {
            return try await presentWebViewCheckout(productId: productId, userId: effectiveUserId)
        }

        // Signal checkout started BEFORE opening browser
        pendingCheckout = true
        delegate?.zeroSettleCheckoutDidBegin(productId: productId)

        // Native Pay: use STPApplePayContext when trait is enabled + device supports it
#if NativePay
        if effectiveType == .nativePay, let nativePayFlow {
            if let merchantId = resolvedMerchantId, nativePayFlow.canMakePayments() {
                ZSLogger.info("Starting native Apple Pay checkout for \(productId)", category: .checkout)
                do {
                    let result = try await nativePayFlow.pay(
                        productId: productId,
                        userId: effectiveUserId,
                        merchantId: merchantId
                    )
                    pendingCheckout = false
                    switch result {
                    case .success(let transaction):
                        delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                        await refreshEntitlementsAfterCheckout(transaction: transaction)
                        await applyOfferCheckoutCompletionIfApplicable(productId: productId, transactionId: transaction.id)
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
                userId: effectiveUserId,
                presentation: presentation
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
                    await applyOfferCheckoutCompletionIfApplicable(productId: productId, transactionId: transaction.id)
                    return transaction
                }
                // Universal link callback fired (success path) but we have no
                // transactionId — meaning create-PI never returned one, so
                // the checkout never had a Transaction record on the backend.
                // The customer was NOT charged. Pre-1.2.5 we threw .cancelled
                // here, which mis-told the dev "user dismissed" when the
                // actual root cause was a backend issue at PI creation.
                // Now: throw checkoutNotStarted so the dev can distinguish.
                ZSLogger.error("Universal link callback fired but session.transactionId is nil — checkout never had a backend Transaction. Customer was not charged.", category: .checkout)
                throw ZeroSettleError.checkoutNotStarted
            }

            // No callback — verify the transaction with the backend before
            // assuming the user abandoned. Use a single attempt (≈1.7s with
            // verifyTransaction's built-in 1.5s webhook-grace sleep) rather
            // than the default 6× retry: in this path the UL did NOT fire,
            // which empirically correlates much more with "user backgrounded
            // Safari without paying" than with "payment succeeded but the
            // webhook is slow". A long poll just delays user feedback. The
            // rare slow-webhook + UL-flake case still resolves on the next
            // entitlement refresh — the user just sees a brief retry
            // affordance instead of a 13s spinner.
            if let transactionId = session.transactionId {
                ZSLogger.debug("No callback — verifying transaction \(transactionId) with backend", category: .checkout)
                do {
                    let transaction = try await backend.verifyTransaction(
                        transactionId: transactionId,
                        maxAttempts: 1
                    )
                    ZSLogger.info("Transaction \(transactionId) confirmed via backend verification", category: .checkout)
                    pendingCheckout = false
                    delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                    await refreshEntitlementsAfterCheckout(transaction: transaction)
                    await applyOfferCheckoutCompletionIfApplicable(productId: productId, transactionId: transaction.id)
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

            let reason: CheckoutFailureReason
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

    /// Presents the hosted WebView checkout sheet for `purchase()` when the
    /// resolved checkout type is `.webView`, bridging `CheckoutSheet`'s
    /// callback-based completion to async/await.
    ///
    /// `CheckoutSheet` creates its own inline-mode checkout session and, on
    /// success, refreshes entitlements, applies offer completion, and fires the
    /// `zeroSettleCheckoutDidComplete` delegate callback — so this method does
    /// not repeat any of that. It owns only what `CheckoutSheet` leaves to the
    /// caller: the `didBegin` signal, the `didCancel`/`didFail` signals (the
    /// sheet fires `didComplete` but not these), and `pendingCheckout` state.
    @MainActor
    private func presentWebViewCheckout(
        productId: String,
        userId: String
    ) async throws -> CheckoutTransaction {
        guard let product = product(for: productId) else {
            throw ZeroSettleError.checkoutFailed(reason: .productNotFound)
        }
        guard let topViewController = SafariPresentation.topViewController() else {
            throw ZeroSettleError.checkoutFailed(
                reason: .other("No view controller available to present the checkout sheet")
            )
        }

        pendingCheckout = true
        delegate?.zeroSettleCheckoutDidBegin(productId: productId)

        do {
            let transaction: CheckoutTransaction = try await withCheckedThrowingContinuation { continuation in
                CheckoutSheet<EmptyView>.present(
                    from: topViewController,
                    product: product,
                    userId: userId,
                    onComplete: { result in
                        continuation.resume(with: result)
                    }
                )
            }
            pendingCheckout = false
            return transaction
        } catch {
            pendingCheckout = false
            if case ZeroSettleError.cancelled = error {
                delegate?.zeroSettleCheckoutDidCancel(productId: productId)
            } else {
                delegate?.zeroSettleCheckoutDidFail(productId: productId, error: error)
            }
            throw error
        }
    }

    /// Purchase a product via native StoreKit 2.
    ///
    /// Use this for products synced to App Store Connect where ``ZSProduct/storeKitAvailable`` is `true`.
    ///
    /// - Important: An identified user is **required**. Call ``ZeroSettle/identify(_:)``
    ///   with `.user(id:)` or `.anonymous` before purchasing — this method throws
    ///   ``ZeroSettleError/userNotIdentified`` otherwise. `.deferred` does not count
    ///   as identified.
    ///
    /// - Parameters:
    ///   - productId: The product identifier to purchase
    ///   - userId: (Deprecated) Explicit app user identifier. Prefer calling
    ///     ``ZeroSettle/identify(_:)`` once, then `purchaseViaStoreKit` without `userId`.
    ///     Will be removed in ZeroSettleKit 2.0.
    /// - Returns: The verified StoreKit transaction
    public func purchaseViaStoreKit(productId: String, userId: String? = nil) async throws -> StoreKit.Transaction {
        guard let storeKitManager else {
            throw ZeroSettleError.notConfigured
        }

        // Purchases require an identified user. Honor an explicitly passed
        // (deprecated) userId; otherwise resolve the user set via identify(_:).
        // Throws userNotIdentified when neither is present. Checked before the
        // product lookup so the identity contract fails fast and consistently.
        let effectiveUserId = try userId ?? requireIdentifiedUserId()

        guard let product = products.first(where: { $0.id == productId }) else {
            throw ZeroSettleError.productNotFound(productId)
        }

        guard let skProduct = product._storeKitProduct else {
            throw ZeroSettleError.productNotFound(productId)
        }

        setActiveUserId(effectiveUserId)

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

    /// Runs a `purchase()` that the backend routed to native StoreKit (the
    /// user's `checkout_routing` cohort is web-checkout-OFF) and returns a
    /// ``CheckoutTransaction`` so `purchase()`'s contract is unchanged.
    ///
    /// Reuses ``purchaseViaStoreKit(productId:userId:)`` so this path inherits
    /// appAccountToken derivation, backend sync (via the StoreKit manager's
    /// verified-transaction handler), and the
    /// `StoreKitPurchaseError → ZeroSettleError` mapping. It then mirrors the
    /// web path's caller-facing side effects — the `didBegin`/`didComplete`/
    /// `didCancel`/`didFail` delegate signals, `pendingCheckout` bookkeeping,
    /// offer completion, and a post-purchase entitlement refresh — so a
    /// store-routed purchase is observationally identical to a web one from the
    /// host app's perspective.
    ///
    /// No second backend sync is issued here: `purchaseViaStoreKit` already
    /// synced the transaction through the StoreKit manager.
    private func purchaseRoutedToStoreKit(
        productId: String,
        userId: String
    ) async throws -> CheckoutTransaction {
        // Mirror the web path's pre-purchase bookkeeping: arm the offer state
        // machine if this purchase is offer-bound (idempotent no-op otherwise).
        // `purchaseViaStoreKit` handles `setActiveUserId` itself.
        armOfferForCheckoutIfApplicable(productId: productId)

        pendingCheckout = true
        delegate?.zeroSettleCheckoutDidBegin(productId: productId)

        do {
            let skTransaction = try await purchaseViaStoreKit(productId: productId, userId: userId)
            pendingCheckout = false

            // Synthesize a CheckoutTransaction from the StoreKit result. The
            // StoreKit sync response carries no ZeroSettle transaction id, so we
            // use the StoreKit transaction id — a pragmatic, stable identifier
            // for this purchase. Source is `.storeKit` (this is a native
            // purchase, not web checkout).
            let transaction = CheckoutTransaction(
                id: String(skTransaction.id),
                productId: productId,
                status: .completed,
                source: .storeKit,
                purchasedAt: skTransaction.purchaseDate,
                expiresAt: skTransaction.expirationDate
            )

            delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
            await refreshEntitlementsAfterCheckout(transaction: transaction)
            await applyOfferCheckoutCompletionIfApplicable(productId: productId, transactionId: transaction.id)
            return transaction
        } catch ZeroSettleError.cancelled {
            pendingCheckout = false
            delegate?.zeroSettleCheckoutDidCancel(productId: productId)
            throw ZeroSettleError.cancelled
        } catch {
            pendingCheckout = false
            ZSLogger.error("StoreKit-routed checkout failed for \(productId): \(error)", category: .checkout)
            delegate?.zeroSettleCheckoutDidFail(productId: productId, error: error)
            throw error
        }
    }

    // MARK: - Migration Tracking

    /// Track a successful migration conversion.
    /// Call this after a user successfully completes a web checkout purchase
    /// as part of a migration campaign (switching from StoreKit to web checkout).
    ///
    /// - Parameter userId: Your app's user identifier
    /// Track a successful migration conversion for the currently identified
    /// user. Requires ``identify(_:)`` to have been called.
    public func trackMigrationConversion() async throws {
        let userId = try requireIdentifiedUserId()
        try await _trackMigrationConversionImpl(userId: userId)
    }

    /// Deprecated. Use ``trackMigrationConversion()`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "trackMigrationConversion()", message: "Call identify(.user(id:)) once, then trackMigrationConversion() without userId. Will be removed in ZeroSettleKit 2.0.")
    public func trackMigrationConversion(userId: String) async throws {
        setActiveUserId(userId)
        try await _trackMigrationConversionImpl(userId: userId)
    }

    internal func _trackMigrationConversionImpl(userId: String) async throws {
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

    /// Fire-and-forget: report that an offer banner was shown on screen.
    /// For integrators who render their own offer UI (the built-in
    /// `OfferTipView` reports automatically). Uses the SDK's per-launch
    /// `sessionId`; the backend dedups once per (user, session, variant).
    public nonisolated static func reportOfferViewed(
        productId: String,
        variantId: Int? = nil,
        flowType: String = "migration"
    ) {
        Task.detached(priority: .utility) {
            let instance = await ZeroSettle.shared
            guard let backend = await instance.backend else {
                ZSLogger.debug("reportOfferViewed: SDK not configured, dropping", category: .general)
                return
            }
            let userId = await instance.storeKitManager?.currentUserId ?? "anonymous"
            let sessionId = await instance.sessionId
            do {
                try await backend.reportOfferViewed(
                    userId: userId, productId: productId,
                    sessionId: sessionId, variantId: variantId, flowType: flowType
                )
                ZSLogger.debug("reportOfferViewed: sent for product=\(productId)", category: .general)
            } catch {
                ZSLogger.debug("reportOfferViewed: failed: \(error)", category: .general)
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
        ZSLogger.info("Incoming URL: \(url.redactedForLogs)", category: .deepLinks)

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

    /// Restore entitlements from both ZeroSettle backend and StoreKit for the
    /// currently identified user. Requires ``identify(_:)``.
    ///
    /// Call this on app launch to recover from missed deeplinks or to sync state.
    /// Merges entitlements from both StoreKit (local) and web checkout (backend).
    ///
    /// If the backend call fails, partial (StoreKit-only) entitlements are still
    /// published to ``entitlements`` before the error is thrown.
    ///
    /// - Returns: The merged entitlements from all sources
    @discardableResult
    public func restoreEntitlements() async throws -> [Entitlement] {
        let userId = try requireIdentifiedUserId()
        return try await _restoreEntitlementsImpl(userId: userId)
    }

    /// Deprecated. Use ``restoreEntitlements()`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "restoreEntitlements()", message: "Call identify(.user(id:)) once, then restoreEntitlements() without userId. Will be removed in ZeroSettleKit 2.0.")
    @discardableResult
    public func restoreEntitlements(userId: String) async throws -> [Entitlement] {
        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ZSLogger.error("restoreEntitlements() called with empty userId", category: .entitlements)
            throw ZeroSettleError.invalidUserId
        }
        setActiveUserId(userId)
        return try await _restoreEntitlementsImpl(userId: userId)
    }

    internal func _restoreEntitlementsImpl(userId: String) async throws -> [Entitlement] {
        let backend = try requireBackend()

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
            // Atomic semantics (post-1.2.5): on backend failure, do NOT
            // mutate the published `entitlements` property. Pre-1.2.5 we
            // would publish the StoreKit-only partial set AND throw
            // restoreEntitlementsFailed — this gave callers contradictory
            // signals (UI showed an error toast while feature gates flipped
            // on based on the partial state). Now: throw and leave the
            // previously-published state intact. The dev gets one clear
            // signal: "the call failed; the published entitlements are
            // unchanged." If they want to fall back to local-only, they can
            // read getCurrentEntitlements() directly.
            //
            // The error case still carries `partialEntitlements` so callers
            // who explicitly want to opt into partial behavior can do so —
            // but the published property is the source of truth and won't
            // disagree with the thrown error.
            throw ZeroSettleError.restoreEntitlementsFailed(
                partialEntitlements: allEntitlements,
                underlyingError: error
            )
        }

        let merged = EntitlementMerge.preservingLocalFallbacks(
            fresh: allEntitlements, prior: entitlements
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
    /// Fetch the full transaction history for the currently identified user.
    /// Requires ``identify(_:)`` to have been called.
    public func fetchTransactionHistory() async throws -> [CheckoutTransaction] {
        let userId = try requireIdentifiedUserId()
        return try await _fetchTransactionHistoryImpl(userId: userId)
    }

    /// Deprecated. Use ``fetchTransactionHistory()`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "fetchTransactionHistory()", message: "Call identify(.user(id:)) once, then fetchTransactionHistory() without userId. Will be removed in ZeroSettleKit 2.0.")
    public func fetchTransactionHistory(userId: String) async throws -> [CheckoutTransaction] {
        setActiveUserId(userId)
        return try await _fetchTransactionHistoryImpl(userId: userId)
    }

    internal func _fetchTransactionHistoryImpl(userId: String) async throws -> [CheckoutTransaction] {
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
    /// Present the cancel flow for the currently identified user. Requires
    /// ``identify(_:)`` to have been called.
    public func presentCancelFlow(productId: String) async -> CancelFlow.Result {
        guard let userId = currentUserId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ZSLogger.error("presentCancelFlow called without identify() — returning .cancelled", category: .cancelFlow)
            return .cancelled
        }
        return await _presentCancelFlowImpl(productId: productId, userId: userId)
    }

    /// Deprecated. Use ``presentCancelFlow(productId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "presentCancelFlow(productId:)", message: "Call identify(.user(id:)) once, then presentCancelFlow(productId:) without userId. Will be removed in ZeroSettleKit 2.0.")
    public func presentCancelFlow(productId: String, userId: String) async -> CancelFlow.Result {
        setActiveUserId(userId)
        return await _presentCancelFlowImpl(productId: productId, userId: userId)
    }

    internal func _presentCancelFlowImpl(productId: String, userId: String) async -> CancelFlow.Result {
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
                    try await _cancelSubscriptionImpl(productId: productId, userId: userId, immediate: false)
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
    /// After ``identify(_:)``, the config is also available synchronously via
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
    /// Accept a save offer for the currently identified user. Requires
    /// ``identify(_:)`` to have been called.
    public func acceptSaveOffer(productId: String) async throws -> CancelFlow.SaveOfferResult {
        let userId = try requireIdentifiedUserId()
        return try await _acceptSaveOfferImpl(productId: productId, userId: userId)
    }

    /// Deprecated. Use ``acceptSaveOffer(productId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "acceptSaveOffer(productId:)", message: "Call identify(.user(id:)) once, then acceptSaveOffer(productId:) without userId. Will be removed in ZeroSettleKit 2.0.")
    public func acceptSaveOffer(productId: String, userId: String) async throws -> CancelFlow.SaveOfferResult {
        setActiveUserId(userId)
        return try await _acceptSaveOfferImpl(productId: productId, userId: userId)
    }

    internal func _acceptSaveOfferImpl(productId: String, userId: String) async throws -> CancelFlow.SaveOfferResult {
        let backend = try requireBackend()

        do {
            let response = try await backend.acceptSaveOffer(productId: productId, userId: userId)
            ZSLogger.info("Save offer accepted: product=\(productId), message=\(response.message)", category: .cancelFlow)

            // Refresh entitlements to reflect the updated subscription
            _ = try? await _restoreEntitlementsImpl(userId: userId)

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
    /// Pause a subscription for the currently identified user. Requires
    /// ``identify(_:)`` to have been called.
    public func pauseSubscription(productId: String, pauseDurationDays: Int?) async throws -> Date? {
        let userId = try requireIdentifiedUserId()
        return try await _pauseSubscriptionImpl(productId: productId, userId: userId, pauseDurationDays: pauseDurationDays)
    }

    /// Deprecated. Use ``pauseSubscription(productId:pauseDurationDays:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "pauseSubscription(productId:pauseDurationDays:)", message: "Call identify(.user(id:)) once, then pauseSubscription(productId:pauseDurationDays:) without userId. Will be removed in ZeroSettleKit 2.0.")
    public func pauseSubscription(productId: String, userId: String, pauseDurationDays: Int?) async throws -> Date? {
        setActiveUserId(userId)
        return try await _pauseSubscriptionImpl(productId: productId, userId: userId, pauseDurationDays: pauseDurationDays)
    }

    internal func _pauseSubscriptionImpl(productId: String, userId: String, pauseDurationDays: Int?) async throws -> Date? {
        let backend = try requireBackend()

        do {
            let response = try await backend.pauseSubscription(
                productId: productId,
                userId: userId,
                pauseDurationDays: pauseDurationDays
            )
            ZSLogger.info("Subscription paused: product=\(productId), resumesAt=\(response.resumesAt?.description ?? "nil")", category: .cancelFlow)

            // Refresh entitlements to reflect the paused state
            _ = try? await _restoreEntitlementsImpl(userId: userId)

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
    /// Resume a paused subscription for the currently identified user.
    /// Requires ``identify(_:)`` to have been called.
    public func resumeSubscription(productId: String) async throws {
        let userId = try requireIdentifiedUserId()
        try await _resumeSubscriptionImpl(productId: productId, userId: userId)
    }

    /// Deprecated. Use ``resumeSubscription(productId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "resumeSubscription(productId:)", message: "Call identify(.user(id:)) once, then resumeSubscription(productId:) without userId. Will be removed in ZeroSettleKit 2.0.")
    public func resumeSubscription(productId: String, userId: String) async throws {
        setActiveUserId(userId)
        try await _resumeSubscriptionImpl(productId: productId, userId: userId)
    }

    internal func _resumeSubscriptionImpl(productId: String, userId: String) async throws {
        let backend = try requireBackend()

        do {
            try await backend.resumeSubscription(productId: productId, userId: userId)
            ZSLogger.info("Subscription resumed: product=\(productId)", category: .cancelFlow)

            // Refresh entitlements to reflect the active state
            _ = try? await _restoreEntitlementsImpl(userId: userId)
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
    /// Cancel a subscription for the currently identified user. Requires
    /// ``identify(_:)`` to have been called.
    public func cancelSubscription(productId: String, immediate: Bool = false) async throws {
        let userId = try requireIdentifiedUserId()
        try await _cancelSubscriptionImpl(productId: productId, userId: userId, immediate: immediate)
    }

    /// Deprecated. Use ``cancelSubscription(productId:immediate:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "cancelSubscription(productId:immediate:)", message: "Call identify(.user(id:)) once, then cancelSubscription(productId:immediate:) without userId. Will be removed in ZeroSettleKit 2.0.")
    public func cancelSubscription(productId: String, userId: String, immediate: Bool = false) async throws {
        setActiveUserId(userId)
        try await _cancelSubscriptionImpl(productId: productId, userId: userId, immediate: immediate)
    }

    internal func _cancelSubscriptionImpl(productId: String, userId: String, immediate: Bool) async throws {
        let backend = try requireBackend()

        do {
            try await backend.cancelSubscription(productId: productId, userId: userId, immediate: immediate)
            ZSLogger.info("Subscription cancelled: product=\(productId), immediate=\(immediate)", category: .cancelFlow)

            // Refresh entitlements to reflect the cancelled state
            _ = try? await _restoreEntitlementsImpl(userId: userId)
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
    /// Present the upgrade offer for the currently identified user. Requires
    /// ``identify(_:)`` to have been called.
    public func presentUpgradeOffer(productId: String? = nil) async -> UpgradeOffer.Result {
        guard let userId = currentUserId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ZSLogger.error("presentUpgradeOffer called without identify() — returning .dismissed", category: .checkout)
            return .dismissed
        }
        return await _presentUpgradeOfferImpl(productId: productId, userId: userId)
    }

    /// Deprecated. Use ``presentUpgradeOffer(productId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "presentUpgradeOffer(productId:)", message: "Call identify(.user(id:)) once, then presentUpgradeOffer(productId:) without userId. Will be removed in ZeroSettleKit 2.0.")
    public func presentUpgradeOffer(productId: String? = nil, userId: String) async -> UpgradeOffer.Result {
        setActiveUserId(userId)
        return await _presentUpgradeOfferImpl(productId: productId, userId: userId)
    }

    internal func _presentUpgradeOfferImpl(productId: String?, userId: String) async -> UpgradeOffer.Result {
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
    /// Fetch the upgrade offer config for the currently identified user.
    /// Requires ``identify(_:)`` to have been called.
    public func fetchUpgradeOfferConfig(productId: String? = nil) async throws -> UpgradeOffer.Config {
        let userId = try requireIdentifiedUserId()
        return try await _fetchUpgradeOfferConfigImpl(productId: productId, userId: userId)
    }

    /// Deprecated. Use ``fetchUpgradeOfferConfig(productId:)`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "fetchUpgradeOfferConfig(productId:)", message: "Call identify(.user(id:)) once, then fetchUpgradeOfferConfig(productId:) without userId. Will be removed in ZeroSettleKit 2.0.")
    public func fetchUpgradeOfferConfig(productId: String? = nil, userId: String) async throws -> UpgradeOffer.Config {
        setActiveUserId(userId)
        return try await _fetchUpgradeOfferConfigImpl(productId: productId, userId: userId)
    }

    internal func _fetchUpgradeOfferConfigImpl(productId: String?, userId: String) async throws -> UpgradeOffer.Config {
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
    /// Fetch the unified user-offer response for the currently identified
    /// user. Requires ``identify(_:)`` to have been called.
    public func fetchUserOffer() async throws -> UserOffer.Response {
        let userId = try requireIdentifiedUserId()
        return try await _fetchUserOfferImpl(userId: userId)
    }

    /// Deprecated. Use ``fetchUserOffer()`` after ``identify(_:)``.
    @available(*, deprecated, renamed: "fetchUserOffer()", message: "Call identify(.user(id:)) once, then fetchUserOffer() without userId. Will be removed in ZeroSettleKit 2.0.")
    public func fetchUserOffer(userId: String) async throws -> UserOffer.Response {
        setActiveUserId(userId)
        return try await _fetchUserOfferImpl(userId: userId)
    }

    internal func _fetchUserOfferImpl(userId: String) async throws -> UserOffer.Response {
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

        // Preserve any local consumable fallbacks (ids prefixed "web_") that
        // were appended by refreshEntitlementsAfterCheckout but aren't
        // persisted as backend EntitlementStates (consumables). Without this
        // merge, background StoreKit syncs would wipe them before the host
        // app observes them via newConsumableEntitlements().
        let publishWithWeb: ([Entitlement]) -> [Entitlement] = { webEnts in
            let merged = EntitlementMerge.preservingLocalFallbacks(
                fresh: storeKitEnts + webEnts, prior: self.entitlements
            )
            self.updateEntitlements(merged)
            return merged
        }

        do {
            let webEntitlements = try await backend.getEntitlements(userId: userId)
            let merged = publishWithWeb(webEntitlements)
            ZSLogger.debug("refreshEntitlementsAndPublish: published \(webEntitlements.count) web + \(storeKitEnts.count) storekit entitlement(s) + \(merged.count - storeKitEnts.count - webEntitlements.count) preserved fallback(s)", category: .entitlements)
        } catch {
            // Even when the backend call fails, republish the fresh StoreKit
            // slice so claims that changed local ownership surface to the UI.
            // Preserve web entitlements (including local fallbacks) so a
            // transient backend error doesn't wipe consumables.
            _ = publishWithWeb(entitlements.filter { $0.source == .webCheckout })
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

        // Nudge offer managers to re-evaluate so upgrade & save can surface
        // immediately after a web purchase without requiring an app relaunch.
        await refreshOfferEligibility()
    }

    /// Re-fetch the product catalog so `remoteConfig.offer` reflects the
    /// latest user-offer eligibility from the backend. Both ``ZSMigrationManager``
    /// and ``ZSOfferManager`` observe ``remoteConfig`` via
    /// `withObservationTracking` and will re-run their eligibility checks
    /// automatically when it changes — so after a StoreKit purchase the
    /// switch & save tip can pop, and after a web purchase the upgrade & save
    /// funnel can surface, without the user having to relaunch the app.
    ///
    /// Failures are logged (inside ``fetchProducts``) but swallowed here —
    /// the purchase that triggered this refresh already succeeded and we
    /// don't want to propagate a stale-catalog error to the checkout path.
    internal func refreshOfferEligibility() async {
        guard let userId = storeKitManager?.currentUserId else { return }
        _ = try? await fetchProducts(userId: userId)
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

    // MARK: - Test hooks

#if DEBUG
    internal func _resetForTesting() {
        offerManager = nil
        // Note: leaves currentConfig/identity intact — tests should configure as needed.
    }
#endif

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
