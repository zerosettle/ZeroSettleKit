//
//  Backend.swift
//  ZeroSettleKit
//
//  Internal API client for ZeroSettle IAP endpoints.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Backend

/// Internal API client for ZeroSettle IAP endpoints.
/// Authenticates requests using the developer's publishable key.
internal final class Backend: @unchecked Sendable {
    private let baseURL: URL
    private let publishableKey: String
    private let httpClient: HTTPClient
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, publishableKey: String) {
        self.baseURL = baseURL
        self.publishableKey = publishableKey

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase

        self.httpClient = HTTPClient(decoder: decoder, encoder: encoder)
    }

    // MARK: - Auth Headers

    private var authHeaders: [String: String] {
        [
            "X-ZeroSettle-Key": publishableKey,
            "X-ZS-SDK-Version": Configuration.sdkVersion,
        ]
    }

    // MARK: - Products

    /// Fetch the product catalog for this developer's app.
    /// - Parameter userId: Optional user ID to check for migration eligibility
    /// - Returns: A ``ProductCatalog`` containing products and remote configuration
    func fetchProducts(userId: String? = nil) async throws -> ProductCatalog {
        var components = URLComponents(url: apiURL("iap/products/"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let userId {
            queryItems.append(URLQueryItem(name: "user_id", value: userId))
        }
        // Demo-mode preview: when the dev has flipped ZSOfferManager.demoMode,
        // ask the server to surface the dashboard-configured campaign of the
        // chosen flow (migration or upgrade) regardless of the user's real
        // subscription state. The backend honors this flag only on test
        // publishable keys (live keys ignore it), so production builds with
        // demoMode somehow set still receive the real, user-state-resolved
        // response. demoMode is @MainActor-isolated; hop explicitly since
        // fetchProducts is non-isolated async.
        let demoMode = await MainActor.run { ZSOfferManager.demoMode }
        if demoMode.isActive {
            queryItems.append(URLQueryItem(name: "demo", value: demoMode.rawValue))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct products URL"))
        }

        let response: ProductsResponse
        do {
            response = try await httpClient.get(
                url,
                headers: authHeaders,
                responseType: ProductsResponse.self
            )
        } catch {
            throw Backend.wrapError(error)
        }

        // Parse remote config if present
        let remoteConfig: RemoteConfig?
        if let configResponse = response.config {
            let checkoutType: CheckoutType
            if let parsed = CheckoutType(rawValue: configResponse.checkout.sheetType) {
                checkoutType = parsed
            } else {
                checkoutType = .webView
                ZSLogger.info("Unrecognized checkout type '\(configResponse.checkout.sheetType)' from backend, defaulting to webView. You may need to update ZeroSettleKit.", category: .network)
            }

            // Parse jurisdiction overrides
            var jurisdictions: [Jurisdiction: JurisdictionCheckoutConfig] = [:]
            if let jurDict = configResponse.checkout.jurisdictions {
                for (key, value) in jurDict {
                    guard let jurisdiction = Jurisdiction(rawValue: key) else { continue }
                    let sheetType: CheckoutType
                    if let parsed = CheckoutType(rawValue: value.sheetType) {
                        sheetType = parsed
                    } else {
                        sheetType = .webView
                        ZSLogger.info("Unrecognized checkout type '\(value.sheetType)' for jurisdiction \(key), defaulting to webView.", category: .network)
                    }
                    jurisdictions[jurisdiction] = JurisdictionCheckoutConfig(
                        sheetType: sheetType,
                        isEnabled: value.isEnabled
                    )
                }
            }

            let checkoutConfig = CheckoutConfig(
                sheetType: checkoutType,
                isEnabled: configResponse.checkout.isEnabled,
                jurisdictions: jurisdictions,
                appleMerchantId: configResponse.checkout.appleMerchantId,
                paymentMethods: configResponse.checkout.paymentMethods
            )

            let migration: MigrationPrompt?
            if let migrationResponse = configResponse.migration {
                let eligible = migrationResponse.eligibleProductIds ?? []

                if migrationResponse.shouldShow,
                   let discountPercent = migrationResponse.discountPercent,
                   let title = migrationResponse.title,
                   let message = migrationResponse.message {
                    let perProductData = migrationResponse.perProductPrompts?.mapValues { pp in
                        MigrationPrompt.PerProductData(
                            discountPercent: pp.discountPercent,
                            title: pp.title,
                            message: pp.message,
                            ctaText: pp.ctaText ?? "Switch Now"
                        )
                    }
                    migration = MigrationPrompt(
                        productId: eligible.first ?? "",
                        eligibleProductIds: eligible,
                        discountPercent: discountPercent,
                        minSubscriptionDays: migrationResponse.minSubscriptionDays ?? 0,
                        maxSubscriptionDays: migrationResponse.maxSubscriptionDays,
                        freeTrialDays: migrationResponse.freeTrialDays ?? 0,
                        title: title,
                        message: message,
                        ctaText: migrationResponse.ctaText ?? "Switch Now",
                        rolloutPercent: migrationResponse.rolloutPercent,
                        perProductPrompts: perProductData
                    )
                } else {
                    migration = nil
                }
            } else {
                migration = nil
            }

            remoteConfig = RemoteConfig(checkout: checkoutConfig, migration: migration, offer: configResponse.offer)
        } else {
            remoteConfig = nil
        }

        return ProductCatalog(products: response.products, config: remoteConfig)
    }

    // MARK: - Checkout Sessions

    /// Create a Stripe checkout session for the given product and user.
    /// The backend creates the session via the developer's connected Stripe Express account.
    /// - Parameters:
    ///   - productId: The product ID to create a checkout session for
    ///   - userId: Optional user ID (for managed user identity scenario)
    ///   - externalUserId: Optional external user ID
    ///   - rcAppUserId: Optional RevenueCat app user ID
    func createCheckoutSession(
        productId: String,
        userId: String? = nil,
        externalUserId: String? = nil,
        rcAppUserId: String? = nil
    ) async throws -> CheckoutSession {
        let url = apiURL("iap/checkout-sessions/")
        let (name, email) = await MainActor.run {
            (ZeroSettle.shared.customerName, ZeroSettle.shared.customerEmail)
        }
        let body = CreateCheckoutSessionRequest(
            productId: productId,
            userId: userId,
            externalUserId: externalUserId,
            rcAppUserId: rcAppUserId,
            customerName: name,
            customerEmail: email
        )
        return try await httpClient.post(
            url,
            body: body,
            headers: authHeaders,
            responseType: CheckoutSession.self
        )
    }

    // MARK: - Checkout

    /// Initiate a checkout for the given product.
    ///
    /// Hits `POST /v1/iap/checkout-configs/` (the deferred-mode entry-point).
    /// The backend decides per-request whether to return a deferred response
    /// (no `clientSecret`; caller subsequently invokes `finalizePaymentIntent`)
    /// or fall through to the legacy intent-first flow (response carries
    /// `clientSecret`). The `deferredMode` discriminator on `CheckoutResponse`
    /// tells the caller which mode they got.
    ///
    /// Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §3.1 §3.2
    func initiateCheckout(productId: String, userId: String? = nil, stripeCustomerId: String? = nil, storekitSubscriptionEnd: Date? = nil, storekitOriginalTransactionId: String? = nil, checkoutMode: CheckoutMode? = nil, externalPurchaseToken: String? = nil) async throws -> CheckoutResponse {
        let url = apiURL("iap/checkout-configs/")
        let iso8601End: String? = storekitSubscriptionEnd.map {
            $0.formatted(.iso8601)
        }
        // Auto-detect the active StoreKit subscription's originalTransactionId
        // when not explicitly provided.  Scoped to the same subscription group
        // as the product being purchased so multi-group apps resolve correctly.
        // The backend uses this to query Apple's App Store Server API for the
        // real expiry and apply a migration trial automatically.
        var resolvedOriginalTxnId = storekitOriginalTransactionId
        if resolvedOriginalTxnId == nil {
            resolvedOriginalTxnId = await MainActor.run {
                guard let targetProduct = ZeroSettle.shared.product(for: productId),
                      let groupId = targetProduct.subscriptionGroupId else { return nil }
                let groupProductIds = Set(ZeroSettle.shared.products
                    .filter { $0.subscriptionGroupId == groupId }
                    .map { $0.id })
                return ZeroSettle.shared.entitlements
                    .first(where: {
                        $0.source == .storeKit &&
                        $0.isActive &&
                        $0.storekitOriginalTransactionId != nil &&
                        groupProductIds.contains($0.productId)
                    })?
                    .storekitOriginalTransactionId
            }
        }
        // Device iOS version — feeds the backend's Apple auto-reporting
        // regime detector (Japan MSCA requires iOS 26.4+). UIKit is always
        // available on iOS; guarded here for non-iOS build targets.
        let (custName, custEmail, iosVersion): (String?, String?, String?) = await MainActor.run {
            let name = ZeroSettle.shared.customerName
            let email = ZeroSettle.shared.customerEmail
            #if canImport(UIKit)
            return (name, email, UIDevice.current.systemVersion)
            #else
            return (name, email, nil)
            #endif
        }
        let body = InitiateCheckoutRequest(
            productId: productId,
            userId: userId,
            stripeCustomerId: stripeCustomerId,
            storekitSubscriptionEnd: iso8601End,
            storekitOriginalTransactionId: resolvedOriginalTxnId,
            checkoutMode: checkoutMode?.rawValue,
            customerName: custName,
            customerEmail: custEmail,
            externalPurchaseToken: externalPurchaseToken,
            iosVersion: iosVersion
        )
        do {
            let response = try await httpClient.post(url, body: body, headers: authHeaders, responseType: CheckoutResponse.self)
            ZSLogger.info(
                "[Backend] initiateCheckout(\(productId)): mode=\(response.deferredMode == true ? "DEFERRED" : "legacy") "
                + "txn=\(response.transactionId) clientSecret=\(response.clientSecret == nil ? "nil" : "<set>")",
                category: .checkout,
            )
            return response
        } catch let error as HTTPError {
            // Retry once on 409 with retry_after — server says a concurrent request
            // (e.g. batch) is creating this PI right now.  Wait then retry; the
            // server's dedup will return the completed transaction.
            if case .httpError(statusCode: 409, body: let data) = error,
               let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawDelay = json["retry_after"] as? Double {
                let retryDelay = min(max(rawDelay, 0.1), 5.0)
                ZSLogger.info("[Backend] PI in-flight for \(productId), retrying in \(retryDelay)s", category: .checkout)
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                return try await wrapped {
                    let response = try await httpClient.post(url, body: body, headers: authHeaders, responseType: CheckoutResponse.self)
                    ZSLogger.info(
                        "[Backend] initiateCheckout(\(productId), retry): mode=\(response.deferredMode == true ? "DEFERRED" : "legacy") "
                        + "txn=\(response.transactionId)",
                        category: .checkout,
                    )
                    return response
                }
            }
            throw Self.wrapError(error)
        } catch {
            throw Self.wrapError(error)
        }
    }

    /// Initiate checkouts for multiple products in a single request.
    /// Shares expensive work (Stripe customer, connect account) across all
    /// products. Hits the mode-aware ``/v1/iap/checkout-configs/batch/``
    /// endpoint — the backend decides per-request whether to defer (no Stripe
    /// calls) or fall through to legacy intent-first based on
    /// ``Tenant.deferred_mode_enabled``. Per-item ``deferredMode`` flag on
    /// the response is the single discriminator the SDK branches on.
    /// (See spec docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §3.4.)
    func initiateCheckoutBatch(products: [BatchCheckoutRequest.ProductEntry], userId: String? = nil, stripeCustomerId: String? = nil) async throws -> BatchCheckoutResponse {
        let url = apiURL("iap/checkout-configs/batch/")
        let (batchName, batchEmail) = await MainActor.run {
            (ZeroSettle.shared.customerName, ZeroSettle.shared.customerEmail)
        }
        let body = BatchCheckoutRequest(products: products, userId: userId, stripeCustomerId: stripeCustomerId, customerName: batchName, customerEmail: batchEmail)
        let response: BatchCheckoutResponse = try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: BatchCheckoutResponse.self)
        }
        // Per-item mode rollup so the dev can confirm at a glance whether
        // the warmup ran in deferred or legacy. All-deferred = success state
        // for a 1.3.0 SDK on a flag-on tenant; mixed = backend or tenant
        // mid-rollout.
        let deferredCount = response.results.filter { $0.deferredMode == true }.count
        let legacyCount = response.results.count - deferredCount
        ZSLogger.info(
            "[Backend] initiateCheckoutBatch: \(response.results.count) item(s) — "
            + "deferred=\(deferredCount) legacy=\(legacyCount)",
            category: .checkout,
        )
        return response
    }

    // MARK: - Transactions

    /// Get the status of a transaction by ID.
    func getTransaction(transactionId: String) async throws -> CheckoutTransaction {
        let url = apiURL("iap/transactions/\(transactionId)/")
        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: CheckoutTransaction.self)
        }
    }

    /// Update the StoreKit subscription status on a transaction.
    func updateStorekitStatus(transactionId: String, storekitStatus: Int, storekitSubscriptionEnd: Date? = nil) async throws {
        let url = apiURL("iap/transactions/\(transactionId)/storekit-status/")
        let body = UpdateStorekitStatusRequest(storekitStatus: storekitStatus, storekitSubscriptionEnd: storekitSubscriptionEnd)
        try await wrapped { try await httpClient.patchVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - Deferred-mode (X-ZS-SDK-Version >= 1.3.0)

    /// Fetch the display data for a deferred-mode checkout config.
    ///
    /// The response carries everything the WebView (or NativePayFlow) needs to
    /// initialize `stripe.elements({mode, amount, currency, paymentMethodConfiguration})`
    /// — but NO `client_secret`. The client_secret is materialized later by
    /// ``finalizePaymentIntent(transactionId:)`` when the user actually
    /// submits, which is the anti-spoof primitive.
    ///
    /// Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §4.1
    func getCheckoutConfig(transactionId: String) async throws -> CheckoutConfigResponse {
        let url = apiURL("iap/checkout-config/\(transactionId)/")
        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: CheckoutConfigResponse.self)
        }
    }

    /// Materialize the Stripe Intent for a deferred-mode checkout config.
    ///
    /// The body is intentionally empty — all parameters come from the
    /// server-resolved Transaction row keyed by `transactionId`. This is the
    /// anti-spoof primitive: the client cannot influence what amount Stripe
    /// sees.
    ///
    /// Idempotent: a second call returns the same `client_secret` without
    /// creating a duplicate Stripe intent.
    ///
    /// Throws ``ZeroSettleError/checkoutConfigExpired`` if the server returns
    /// HTTP 410 (the underlying `checkout_config_expires_at` has passed); the
    /// caller should restart checkout via ``initiateCheckout(productId:userId:stripeCustomerId:storekitSubscriptionEnd:storekitOriginalTransactionId:checkoutMode:externalPurchaseToken:)``
    /// rather than retrying.
    ///
    /// Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §4.1
    func finalizePaymentIntent(transactionId: String) async throws -> String {
        let url = apiURL("iap/payment-intents/\(transactionId)/finalize/")
        do {
            let response: FinalizePaymentIntentResponse = try await httpClient.post(
                url,
                headers: authHeaders,
                responseType: FinalizePaymentIntentResponse.self
            )
            return response.clientSecret
        } catch let error as HTTPError {
            if case .httpError(statusCode: 410, _) = error {
                throw ZeroSettleError.checkoutConfigExpired
            }
            throw Self.wrapError(error)
        } catch {
            throw Self.wrapError(error)
        }
    }

    // MARK: - Transaction Verification

    /// Poll the backend to verify a transaction has completed.
    ///
    /// Waits an initial 1.5s for webhook processing, then polls `getTransaction()`
    /// up to `maxAttempts` times. Returns the transaction on `.completed` or
    /// `.processing` (final attempt), throws on pending/failed or timeout.
    func verifyTransaction(
        transactionId: String,
        maxAttempts: Int = 6,
        pollInterval: UInt64 = 2_000_000_000
    ) async throws -> CheckoutTransaction {
        // Initial delay for webhook processing
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var lastTransaction: CheckoutTransaction?
        for attempt in 1...maxAttempts {
            let transaction = try await getTransaction(transactionId: transactionId)
            lastTransaction = transaction

            switch transaction.status {
            case .completed:
                return transaction
            case .processing, .pending:
                // Webhook may still be processing — keep polling
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    continue
                }
                // Final attempt: processing is success-like, pending means webhook never arrived
                if transaction.status == .processing {
                    return transaction
                }
                throw PaymentSheetError.verificationTimedOut
            default:
                // .failed, .refunded — terminal error states
                throw PaymentSheetError.transactionFailed(status: transaction.status.rawValue)
            }
        }
        if let txn = lastTransaction { return txn }
        throw PaymentSheetError.verificationFailed("Verification timed out")
    }

    // MARK: - Entitlements

    /// Get the current entitlements for a user.
    func getEntitlements(userId: String) async throws -> [Entitlement] {
        var components = URLComponents(url: apiURL("iap/entitlements/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct entitlements URL"))
        }

        let response: EntitlementsResponse = try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: EntitlementsResponse.self)
        }
        return response.entitlements
    }

    // MARK: - Transaction History

    /// Get all transactions for a user (including consumed, expired, refunded).
    func getTransactionHistory(userId: String) async throws -> [CheckoutTransaction] {
        var components = URLComponents(url: apiURL("iap/transaction-history/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct transaction history URL"))
        }

        let response: TransactionHistoryResponse = try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: TransactionHistoryResponse.self)
        }
        return response.transactions
    }

    // MARK: - Migration Tracking

    /// Track a successful migration conversion (user switched from StoreKit to web checkout).
    func trackMigrationConversion(userId: String) async throws {
        let url = apiURL("iap/migration-converted/")
        let body = MigrationConversionRequest(userId: userId)
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - StoreKit Transaction Sync

    /// Forward a StoreKit transaction's JWS representation for server-side verification.
    /// Returns ownership info: `owned` is true if this transaction belongs to the current user.
    ///
    /// - Parameters:
    ///   - jwsRepresentation: The verified JWS payload from StoreKit.
    ///   - userId: Your app's user identifier.
    ///   - willAutoRenew: Optional latest `RenewalInfo.willAutoRenew` observed
    ///     by the SDK. When supplied, the backend can reconcile Apple-side
    ///     cancellations without waiting on ASSN v2. Backend added support
    ///     via Patch 2B; older servers ignore the extra key.
    ///   - renewalState: Optional latest `SubscriptionInfo.RenewalState` (e.g.
    ///     `subscribed`, `expired`, `revoked`). Paired with `willAutoRenew`.
    func syncStoreKitTransaction(
        jwsRepresentation: String,
        userId: String,
        willAutoRenew: Bool? = nil,
        renewalState: String? = nil
    ) async throws -> SyncStoreKitTransactionResponse {
        let url = apiURL("iap/storekit-transactions/")
        let (customerName, customerEmail) = await MainActor.run {
            (ZeroSettle.shared.customerName, ZeroSettle.shared.customerEmail)
        }
        let body = SyncStoreKitTransactionRequest(
            jwsRepresentation: jwsRepresentation,
            userId: userId,
            willAutoRenew: willAutoRenew,
            renewalState: renewalState,
            customerName: customerName,
            customerEmail: customerEmail
        )
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: SyncStoreKitTransactionResponse.self)
        }
    }

    /// Bulk reconcile of StoreKit subscription states (Spec 3 append-log mode).
    ///
    /// POSTs to the same endpoint as syncStoreKitTransaction. Backend
    /// dispatches based on the `transactions` array key — when present,
    /// it routes to the bulk reconcile handler. Legacy single-tx callers
    /// (syncStoreKitTransaction above) are unaffected.
    ///
    /// - Parameters:
    ///   - entries: Built by `SubscriptionStateReconciler.gather()`.
    ///   - userId: The developer's user identifier.
    ///   - clientRequestId: SDK-generated UUID per call; logged for support.
    ///   - clientSdkVersion: For future migration / deprecation tracking.
    func reconcileSubscriptionStates(
        entries: [SubscriptionStateEntry],
        userId: String,
        clientRequestId: String = UUID().uuidString,
        clientSdkVersion: String = "unknown"
    ) async throws -> ReconcileSubscriptionStatesResponse {
        let url = apiURL("iap/storekit-transactions/")
        let body = ReconcileSubscriptionStatesRequest(
            transactions: entries,
            userId: userId,
            clientRequestId: clientRequestId,
            clientSdkVersion: clientSdkVersion
        )
        return try await wrapped {
            try await httpClient.post(
                url, body: body, headers: authHeaders,
                responseType: ReconcileSubscriptionStatesResponse.self
            )
        }
    }

    /// Explicitly claim a StoreKit entitlement for the current user, even if
    /// another ZeroSettle account originally purchased it on this Apple ID.
    func claimEntitlement(jwsRepresentation: String, userId: String) async throws -> ClaimEntitlementResponse {
        let url = apiURL("iap/claim-entitlement/")
        let body = SyncStoreKitTransactionRequest(
            jwsRepresentation: jwsRepresentation,
            userId: userId,
            willAutoRenew: nil,
            renewalState: nil,
            customerName: nil,
            customerEmail: nil
        )
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: ClaimEntitlementResponse.self)
        }
    }

    // MARK: - Cancel Flow

    /// Fetch the cancel flow configuration for this app.
    /// - Parameter userId: Optional user ID for A/B experiment targeting
    func fetchCancelFlow(userId: String? = nil) async throws -> CancelFlow.Config {
        var components = URLComponents(url: apiURL("iap/cancel-flow/"), resolvingAgainstBaseURL: false)!
        if let userId {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        }

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct cancel flow URL"))
        }

        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: CancelFlow.Config.self)
        }
    }

    /// Submit a cancel flow response (fire-and-forget from the caller's perspective).
    func submitCancelFlowResponse(_ payload: CancelFlow.ResponsePayload) async throws {
        let url = apiURL("iap/cancel-flow/respond/")
        try await wrapped { try await httpClient.postVoid(url, body: payload, headers: authHeaders) }
    }

    /// Accept the save offer for a cancel flow, applying the discount on Stripe.
    func acceptSaveOffer(productId: String, userId: String) async throws -> AcceptSaveOfferResponse {
        let url = apiURL("iap/cancel-flow/accept-offer/")
        let body = AcceptSaveOfferRequest(productId: productId, userId: userId)
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: AcceptSaveOfferResponse.self)
        }
    }

    // MARK: - Subscription Pause/Resume/Cancel

    /// Pause a subscription for the given product and user.
    /// - Parameters:
    ///   - productId: The product to pause
    ///   - userId: The user who owns the subscription
    ///   - pauseDurationDays: Number of days to pause, or nil for indefinite
    /// - Returns: A ``PauseSubscriptionResponse`` with the resume date
    func pauseSubscription(productId: String, userId: String, pauseDurationDays: Int?) async throws -> PauseSubscriptionResponse {
        let url = apiURL("iap/subscriptions/pause/")
        let body = PauseSubscriptionRequest(productId: productId, userId: userId, pauseDurationDays: pauseDurationDays)
        return try await wrapped {
            try await httpClient.post(url, body: body, headers: authHeaders, responseType: PauseSubscriptionResponse.self)
        }
    }

    /// Resume a paused subscription.
    func resumeSubscription(productId: String, userId: String) async throws {
        let url = apiURL("iap/subscriptions/resume/")
        let body = ResumeSubscriptionRequest(productId: productId, userId: userId)
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    /// Cancel a subscription.
    func cancelSubscription(productId: String, userId: String, immediate: Bool) async throws {
        let url = apiURL("iap/subscriptions/cancel/")
        let body = CancelSubscriptionRequest(productId: productId, userId: userId, immediate: immediate)
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - Upgrade Offer

    /// Fetch the upgrade offer configuration for a user/product.
    func fetchUpgradeOffer(userId: String, productId: String? = nil) async throws -> UpgradeOffer.Config {
        var components = URLComponents(url: apiURL("iap/upgrade-offer/"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "user_id", value: userId)]
        if let productId {
            queryItems.append(URLQueryItem(name: "product_id", value: productId))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct upgrade offer URL"))
        }

        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: UpgradeOffer.Config.self)
        }
    }

    // MARK: - User Offer (SDK 1.2+)

    /// Fetch the unified user-offer response: the user's current subscription
    /// state plus the server-canonical offer decision.
    func fetchUserOffer(userId: String) async throws -> UserOffer.Response {
        var components = URLComponents(url: apiURL("iap/user-offer/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct user-offer URL"))
        }

        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: UserOffer.Response.self)
        }
    }

    /// Execute a subscription upgrade (web-to-web or storekit-to-web).
    func executeUpgradeOffer(_ request: UpgradeOffer.ExecuteRequest) async throws -> UpgradeOfferExecuteResponse {
        let url = apiURL("iap/upgrade-offer/execute/")
        return try await wrapped {
            try await httpClient.post(url, body: request, headers: authHeaders, responseType: UpgradeOfferExecuteResponse.self)
        }
    }

    /// Submit a declined/dismissed response for an upgrade offer.
    func respondUpgradeOffer(_ request: UpgradeOffer.RespondRequest) async throws {
        let url = apiURL("iap/upgrade-offer/respond/")
        try await wrapped { try await httpClient.postVoid(url, body: request, headers: authHeaders) }
    }

    // MARK: - StoreKit Subscription Status (Server-Side)

    /// Query the server for real-time Apple subscription status (bypasses on-device cache).
    func getStoreKitSubscriptionStatus(originalTransactionId: String) async throws -> StoreKitSubscriptionStatusResponse {
        var components = URLComponents(url: apiURL("iap/storekit-subscription-status/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "original_transaction_id", value: originalTransactionId)]

        guard let url = components.url else {
            throw Backend.wrapError(HTTPError.invalidURL("Failed to construct storekit-subscription-status URL"))
        }

        return try await wrapped {
            try await httpClient.get(url, headers: authHeaders, responseType: StoreKitSubscriptionStatusResponse.self)
        }
    }

    // MARK: - Funnel Analytics

    /// Send a funnel analytics event (fire-and-forget from the caller's perspective).
    func trackFunnelEvent(
        eventType: String,
        userId: String,
        productId: String,
        screenName: String?,
        metadata: [String: String]?
    ) async throws {
        let url = apiURL("iap/events/")
        let body = TrackFunnelEventRequest(
            eventType: eventType,
            userId: userId,
            productId: productId,
            screenName: screenName,
            metadata: metadata
        )
        try await wrapped { try await httpClient.postVoid(url, body: body, headers: authHeaders) }
    }

    // MARK: - Error Wrapping

    /// Convert any error thrown by the HTTP layer into a typed ``ZeroSettleError/apiError(_:)``.
    /// If the error is already a ``ZeroSettleError``, it passes through unchanged.
    static func wrapError(_ error: Error) -> ZeroSettleError {
        if let iapError = error as? ZeroSettleError {
            return iapError
        }

        let detail = parseAPIErrorDetail(from: error)
        return .apiError(detail)
    }

    /// Parse an `HTTPError` (or any `Error`) into a structured `APIErrorDetail`.
    private static func parseAPIErrorDetail(from error: Error) -> APIErrorDetail {
        guard let httpError = error as? HTTPError else {
            return APIErrorDetail(
                statusCode: nil,
                serverMessage: nil,
                serverCode: nil,
                underlyingError: error
            )
        }

        switch httpError {
        case .httpError(let statusCode, let body):
            var serverMessage: String?
            var serverCode: String?

            if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                serverMessage = json["error"] as? String ?? json["message"] as? String ?? json["detail"] as? String
                serverCode = json["code"] as? String
            }

            return APIErrorDetail(
                statusCode: statusCode,
                serverMessage: serverMessage,
                serverCode: serverCode,
                underlyingError: error
            )

        case .networkError:
            return APIErrorDetail(
                statusCode: nil,
                serverMessage: nil,
                serverCode: nil,
                underlyingError: error
            )

        default:
            return APIErrorDetail(
                statusCode: nil,
                serverMessage: nil,
                serverCode: nil,
                underlyingError: error
            )
        }
    }

    // MARK: - Helpers

    /// Wraps an async operation with consistent error conversion to ``ZeroSettleError/apiError(_:)``.
    private func wrapped<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { throw Self.wrapError(error) }
    }

    /// Builds a full request URL for an API `path` (e.g. `iap/products/`).
    ///
    /// Backend endpoints are versioned under `/v1`. `baseURL` may be supplied
    /// as the bare API origin (`https://api.zerosettle.io`) or already ending
    /// in `/v1` — both normalize to exactly one `/v1` segment, so callers and
    /// `setBaseUrlOverride` need not care which form is passed. This keeps the
    /// base-URL contract consistent with the Android SDK, which takes the bare
    /// origin and versions the path itself.
    internal func apiURL(_ path: String) -> URL {
        let versioned = baseURL.lastPathComponent == "v1"
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        return versioned.appendingPathComponent(path)
    }
}

// MARK: - Request/Response Models

private struct ProductsResponse: Decodable {
    let products: [ZSProduct]
    let config: ConfigResponse?
}

private struct ConfigResponse: Decodable {
    let checkout: CheckoutFlowConfigResponse
    let migration: MigrationPromptResponse?
    let offer: Offer.OfferData?
}

/// Renamed from `CheckoutConfigResponse` to free up that name for the
/// module-scope deferred-mode model in `Models/CheckoutConfigResponse.swift`.
/// This struct is the legacy "remote config block" inside `/iap/products/`'s
/// response — distinct from the new `GET /iap/checkout-config/<id>/` payload.
private struct CheckoutFlowConfigResponse: Decodable {
    let sheetType: String
    let isEnabled: Bool
    let jurisdictions: [String: JurisdictionConfigResponse]?
    let appleMerchantId: String?
    let paymentMethods: [String]?
}

private struct JurisdictionConfigResponse: Decodable {
    let sheetType: String
    let isEnabled: Bool
}

private struct MigrationPromptResponse: Decodable {
    let shouldShow: Bool
    let eligibleProductIds: [String]?
    let discountPercent: Int?
    let minSubscriptionDays: Int?
    let maxSubscriptionDays: Int?
    let freeTrialDays: Int?
    let title: String?
    let message: String?
    let ctaText: String?
    let rolloutPercent: Int?
    let perProductPrompts: [String: PerProductPromptResponse]?
}

private struct PerProductPromptResponse: Decodable {
    let discountPercent: Int
    let title: String
    let message: String
    let ctaText: String?
}

private struct EntitlementsResponse: Decodable {
    let entitlements: [Entitlement]
}

private struct TransactionHistoryResponse: Decodable {
    let transactions: [CheckoutTransaction]
}

internal struct CreateCheckoutSessionRequest: Encodable {
    let productId: String
    let userId: String?
    let externalUserId: String?
    let rcAppUserId: String?
    let platform: String = "ios"
    let customerName: String?
    let customerEmail: String?
}

internal struct InitiateCheckoutRequest: Encodable {
    let productId: String
    let userId: String?
    let stripeCustomerId: String?
    let storekitSubscriptionEnd: String?
    let storekitOriginalTransactionId: String?
    let checkoutMode: String?
    let platform: String = "ios"
    let customerName: String?
    let customerEmail: String?
    /// Apple external-purchase token (from `ExternalPurchase` disclosure sheet).
    /// Required for Apple auto-reporting — the backend gracefully handles nil.
    let externalPurchaseToken: String?
    /// Device iOS version (e.g. "26.4.1") — used by the backend regime detector
    /// to decide whether a transaction qualifies for Japan MSCA reporting.
    let iosVersion: String?
}

internal struct UpdateStorekitStatusRequest: Encodable {
    let storekitStatus: Int
    let storekitSubscriptionEnd: Date?
}

/// Response from the checkout initiation endpoint.
/// Contains the checkout URL and metadata for rendering the payment UI.
///
/// `clientSecret` and `deferredMode` are the dual-mode discriminators:
///
/// - `deferredMode == true` => `clientSecret` is `nil`. The caller must
///   invoke `Backend.finalizePaymentIntent(transactionId:)` later (typically
///   when the user taps Pay) to materialize the Stripe intent.
/// - `deferredMode == false` (or absent, for legacy backend responses) =>
///   `clientSecret` is non-nil. This is the legacy intent-first contract:
///   the SDK confirms the PaymentIntent / SetupIntent immediately.
///
/// Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §3.1
internal struct CheckoutResponse: Decodable {
    /// Non-nil on the legacy fall-through path (`deferredMode == false`).
    /// `nil` on the deferred-mode path (`deferredMode == true`); caller must
    /// call `Backend.finalizePaymentIntent(transactionId:)` to materialize.
    let clientSecret: String?
    let transactionId: String
    let amount: Int
    let currency: String
    let productName: String
    let originalAmount: Int?
    let callbackUrl: String
    let publishableKey: String
    let checkoutUrl: String
    /// BYOS: connected account ID for PaymentIntent confirmation.
    let stripeAccount: String?
    /// ISO country code of the connected Stripe account (for Apple Pay).
    let merchantCountry: String?
    /// Whether this is a recurring (subscription) payment.
    let isSubscription: Bool?
    /// Billing interval for subscriptions: "week", "month", "year".
    let subscriptionInterval: String?
    /// Unix timestamp for trial end (migration free trials). When set, amount is 0 and payment is deferred.
    let trialEnd: Int?
    /// The amount (in cents) the customer will be charged when the trial ends.
    let pendingAmount: Int?
    /// `true` => deferred-mode response (no `clientSecret`; call `finalizePaymentIntent`
    /// to materialize). `false` => legacy fall-through (the response carries
    /// `clientSecret`). Optional because pre-Task-14 backend responses don't
    /// include the field; treat absent as "legacy fall-through".
    let deferredMode: Bool?
}

// MARK: - Batch Checkout

internal struct BatchCheckoutRequest: Encodable {
    struct ProductEntry: Encodable {
        let productId: String
        let storekitSubscriptionEnd: String?
        let storekitOriginalTransactionId: String?
    }
    let products: [ProductEntry]
    let userId: String?
    let stripeCustomerId: String?
    let platform: String = "ios"
    let customerName: String?
    let customerEmail: String?
}

internal struct BatchCheckoutResponse: Decodable {
    struct Result: Decodable {
        let productId: String
        let error: String?
        // All CheckoutResponse fields as optionals (absent when error is set)
        let clientSecret: String?
        let transactionId: String?
        let amount: Int?
        let currency: String?
        let productName: String?
        let originalAmount: Int?
        let callbackUrl: String?
        let publishableKey: String?
        let checkoutUrl: String?
        let stripeAccount: String?
        let merchantCountry: String?
        let isSubscription: Bool?
        let subscriptionInterval: String?
        let trialEnd: Int?
        let pendingAmount: Int?
        /// Forwarded from `CheckoutResponse.deferredMode`. The batch endpoint
        /// is always-deferred today (Phase 1 Task 6); a future task will add
        /// fall-through for the batch path on a per-item basis.
        let deferredMode: Bool?

        /// Convert a successful result to a full CheckoutResponse.
        ///
        /// Note: `clientSecret` becomes optional on `CheckoutResponse` as of
        /// Task 14. We still require `transactionId` and the display fields,
        /// but a successful deferred-mode batch item legitimately has
        /// `clientSecret == nil`; the guard below no longer requires it.
        func asCheckoutResponse() -> CheckoutResponse? {
            guard error == nil,
                  let transactionId, let amount,
                  let currency, let productName, let callbackUrl,
                  let publishableKey, let checkoutUrl else { return nil }
            return CheckoutResponse(
                clientSecret: clientSecret,
                transactionId: transactionId,
                amount: amount,
                currency: currency,
                productName: productName,
                originalAmount: originalAmount,
                callbackUrl: callbackUrl,
                publishableKey: publishableKey,
                checkoutUrl: checkoutUrl,
                stripeAccount: stripeAccount,
                merchantCountry: merchantCountry,
                isSubscription: isSubscription,
                subscriptionInterval: subscriptionInterval,
                trialEnd: trialEnd,
                pendingAmount: pendingAmount,
                deferredMode: deferredMode
            )
        }
    }
    let results: [Result]
}

/// Response shape for `POST /v1/iap/payment-intents/<id>/finalize/`. The
/// endpoint returns just the freshly-materialized Stripe `client_secret`;
/// callers don't need the response struct itself, only the secret string.
/// No explicit `CodingKeys` — the shared decoder's `.convertFromSnakeCase`
/// handles `client_secret` → `clientSecret`.
private struct FinalizePaymentIntentResponse: Decodable {
    let clientSecret: String
}

private struct SyncStoreKitTransactionRequest: Encodable {
    let jwsRepresentation: String
    let userId: String
    /// Latest `RenewalInfo.willAutoRenew` observed by the SDK (Patch 2B).
    /// Older backends ignore this field.
    let willAutoRenew: Bool?
    /// Latest `Product.SubscriptionInfo.RenewalState` observed by the SDK.
    /// Raw values match `StoreKitSubscriptionMonitor.RenewalState.rawValue`.
    let renewalState: String?
    /// Customer display name from `ZeroSettle.shared.customerName` (set during bootstrap).
    /// Backend uses this to backfill `Identity.name` on StoreKit-only accounts.
    let customerName: String?
    /// Customer email from `ZeroSettle.shared.customerEmail` (set during bootstrap).
    let customerEmail: String?
}

internal struct SyncStoreKitTransactionResponse: Decodable {
    let status: String
    let owned: Bool?
    let originalTransactionId: String?
    // Cross-user OTID conflict signals (backend Task 5 of Spec 1).
    // Optional for backward compat: older backends omit these.
    let conflict: Bool?
    let claimAvailable: Bool?
    let existingOwnerHint: String?

    // No explicit CodingKeys — the shared decoder's
    // `.convertFromSnakeCase` (Backend.swift:35) maps snake_case
    // JSON keys to camelCase property names automatically.
    // An explicit `case originalTransactionId = "original_transaction_id"`
    // would BREAK decoding because the strategy transforms JSON keys
    // to camelCase BEFORE matching against CodingKey raw values.
}

internal struct ReconcileSubscriptionStatesRequest: Encodable {
    let transactions: [SubscriptionStateEntry]
    let userId: String
    let clientRequestId: String
    let clientSdkVersion: String

    enum CodingKeys: String, CodingKey {
        case transactions
        case userId = "user_id"
        case clientRequestId = "client_request_id"
        case clientSdkVersion = "client_sdk_version"
    }
}

internal struct ReconcileSubscriptionStatesResponse: Decodable {
    let status: String
    let processed: Int
    let eventsEmitted: Int
    let skipped: [SkipEntry]?

    struct SkipEntry: Decodable {
        let reason: String
        let transactionId: String?
        // No explicit CodingKeys — the shared decoder's
        // `.convertFromSnakeCase` maps JSON `transaction_id` →
        // Swift `transactionId` automatically. An explicit
        // `case transactionId = "transaction_id"` here would BREAK
        // decoding under `.convertFromSnakeCase`: the strategy
        // transforms JSON keys to camelCase BEFORE matching
        // against CodingKey raw values, so a snake_case raw value
        // never matches.
    }

    // No explicit CodingKeys — see the comment on `SkipEntry`.
    // Adding `case eventsEmitted = "events_emitted"` here was a
    // production bug: it caused `keyNotFound` on every reconcile
    // response despite the field being present in the JSON.
}

internal struct ClaimEntitlementResponse: Decodable {
    let status: String
    let claimed: Bool?
    let productId: String?
    let originalTransactionId: String?
    let message: String?

    // No explicit CodingKeys — the shared decoder's
    // `.convertFromSnakeCase` (Backend.swift:35) handles snake_case
    // JSON → camelCase Swift mapping. See ReconcileSubscriptionStatesResponse
    // for the full explanation of why explicit snake_case raw values
    // break under `.convertFromSnakeCase`.
}

private struct MigrationConversionRequest: Encodable {
    let userId: String
}

internal struct PauseSubscriptionRequest: Encodable {
    let productId: String
    let userId: String
    let pauseDurationDays: Int?
}

internal struct PauseSubscriptionResponse: Decodable {
    let resumesAt: Date?
}

internal struct ResumeSubscriptionRequest: Encodable {
    let productId: String
    let userId: String
}

internal struct CancelSubscriptionRequest: Encodable {
    let productId: String
    let userId: String
    let immediate: Bool
}

internal struct AcceptSaveOfferRequest: Encodable {
    let productId: String
    let userId: String
}

internal struct AcceptSaveOfferResponse: Decodable {
    let message: String
    let discountPercent: Int?
    let durationMonths: Int?
}

internal struct UpgradeOfferExecuteResponse: Decodable {
    let success: Bool
    let upgradeType: String?
    let checkoutUrl: String?
    let sessionId: String?
    let transactionId: String?
    let cancelInstructions: String?
}

internal struct TrackFunnelEventRequest: Encodable {
    let eventType: String
    let userId: String
    let productId: String
    let screenName: String?
    let metadata: [String: String]?
}

internal struct StoreKitSubscriptionStatusResponse: Decodable {
    /// 1 = active (subscribed + auto-renew on), 2 = cancelled/expired/other
    let status: Int
    /// 0 = auto-renew off, 1 = auto-renew on
    let autoRenewStatus: Int
    /// Subscription expiration date, if available
    let expiresAt: Date?
    /// Canonical "granting access" flag from backend 2026-04-20+.
    /// Absent on older backends — use ``resolvedIsActive`` for safe access.
    let isActive: Bool?
    /// Canonical auto-renew flag from backend 2026-04-20+. Absent on older backends.
    let autoRenewEnabled: Bool?

    /// Canonical "is this subscription currently granting access?" answer.
    /// Prefers the server-provided ``isActive`` flag from backend 2026-04-20+;
    /// falls back to the legacy heuristic (`status == 1`) for older backends.
    var resolvedIsActive: Bool {
        if let serverProvided = isActive {
            return serverProvided
        }
        return status == 1
    }
}

#if DEBUG
extension Backend {
    /// Test-only accessor for verifying authHeaders contents.
    /// Do NOT use from production code.
    internal var testAuthHeaders: [String: String] { authHeaders }
}
#endif
