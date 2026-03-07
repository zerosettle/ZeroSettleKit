//
//  ZSMigrationManager.swift
//  ZeroSettleKit
//
//  Observable manager for the StoreKit → web checkout migration flow.
//  Extracts business logic from MigrationTipView so developers can
//  build custom migration UIs while reusing eligibility, state transitions,
//  and checkout orchestration.
//

import Foundation
import SwiftUI
import StoreKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Manages the migration offer lifecycle for a single user.
///
/// Use this as a `@StateObject` to observe migration eligibility and drive
/// custom UIs, or let ``MigrationTipView`` use it internally.
///
/// ```swift
/// @StateObject private var migration = ZSMigrationManager(userId: "user_42")
///
/// var body: some View {
///     if migration.state == .eligible, let offer = migration.offerData {
///         Text(offer.prompt.message)
///         Button("Switch Now") { migration.present() }
///     }
/// }
/// ```
@MainActor
public final class ZSMigrationManager: ObservableObject {

    // MARK: - Published State

    /// The current state of the migration offer.
    @Published public private(set) var state: MigrationOffer.State = .loading

    /// Offer details available when ``state`` is `.eligible` or later.
    @Published public private(set) var offerData: MigrationOffer.OfferData?

    /// The last checkout error, if any.
    @Published public private(set) var checkoutError: Error?

    /// Whether a network operation (checkout creation) is in progress.
    @Published public private(set) var isLoading: Bool = false

    /// Whether the user still needs to cancel their Apple subscription.
    /// `true` after subscription management was shown but the subscription is still active.
    @Published public private(set) var storekitCancelRequired: Bool = false

    /// The transaction ID from the checkout, used to update StoreKit status on the backend.
    private var checkoutTransactionId: String?

    // MARK: - Public Properties

    /// The user identifier for this migration flow.
    public let userId: String

    /// An optional existing Stripe Customer ID (`cus_xxx`) to attach the
    /// migration checkout to.  When provided the backend will use this customer
    /// instead of creating a new one, ensuring a unified Billing Portal view.
    public let stripeCustomerId: String?

    // MARK: - Demo Mode

    /// Enables demo mode for previewing the migration UI without an active StoreKit subscription.
    ///
    /// When `true`, ``evaluateEligibility()`` skips the active StoreKit subscription check and
    /// the "no active web entitlements" check, synthesizing a demo ``MigrationPrompt`` instead.
    /// The SDK must still be configured and bootstrapped, and the dismissed check is still respected.
    ///
    /// Set this before calling ``ZeroSettle/bootstrap(userId:)`` for best results.
    public static var demoMode: Bool = false

    // MARK: - Persistence

    private static let dismissedKey = "com.zerosettle.migrateTipDismissed"

    /// Whether the migration tip has been permanently dismissed (persisted across app launches).
    public static var isPermanentlyDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    /// Resets the dismissed state, allowing the migration offer to be shown again.
    public static func resetDismissedState() {
        ZSLogger.info("[MigrationManager] resetDismissedState() called — clearing persisted dismissal", category: .migration)
        isPermanentlyDismissed = false
    }

    // MARK: - Initialization

    /// Creates a migration manager for the given user.
    ///
    /// The manager immediately evaluates eligibility based on the current state
    /// of ``ZeroSettle/shared`` and re-evaluates whenever observed properties change.
    ///
    /// - Parameters:
    ///   - userId: Your app's user identifier
    ///   - stripeCustomerId: Optional existing Stripe Customer ID (`cus_xxx`)
    ///     to attach the checkout to.  When `nil` the backend creates a new customer.
    public init(userId: String, stripeCustomerId: String? = nil) {
        self.userId = userId
        self.stripeCustomerId = stripeCustomerId
        ZSLogger.info("[MigrationManager] init(userId: \"\(userId)\", stripeCustomerId: \"\(stripeCustomerId ?? "nil")\")", category: .migration)

        // Evaluate immediately and start observing ZeroSettle.shared for changes
        startObserving()
        ZSLogger.info("[MigrationManager] Started observation tracking for re-evaluation", category: .migration)
    }

    /// Observes `ZeroSettle.shared` properties read by `evaluateEligibility()` and
    /// re-evaluates whenever any of them change.
    private func startObserving() {
        withObservationTracking {
            evaluateEligibility()
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self,
                      self.state == .loading || self.state == .ineligible || self.state == .eligible else { return }
                ZSLogger.info("[MigrationManager] Observation change detected — re-evaluating eligibility", category: .migration)
                self.startObserving()
            }
        }
    }

    // MARK: - Eligibility

    /// Re-evaluates eligibility as a sequential checklist.
    /// Each check either returns early (not eligible) or falls through to the next.
    /// Mid-flow states (.presented, .accepted, .completed, .dismissed) are locked.
    private func evaluateEligibility() {
        // Demo mode: force out of dismissed state so re-evaluation can proceed
        if Self.demoMode && state == .dismissed {
            state = .loading
        }

        let previousState = state
        let iap = ZeroSettle.shared

        // ── Always sync Apple subscription status to backend ──
        let syncEntitlement = iap.entitlements.first(where: { $0.source == .storeKit })
            ?? iap.entitlements.first(where: { $0.source == .webCheckout })
        let syncProductId = syncEntitlement?.productId
        let syncOrigTxnId = syncEntitlement?.storekitOriginalTransactionId
        if let syncProductId {
            Task { [weak self] in
                guard let self else { return }
                // Try server-side first (real-time), fall back to on-device StoreKit
                var result = await self.fetchAppleSubscriptionStatusFromServer(originalTransactionId: syncOrigTxnId)
                if result == nil {
                    result = await self.fetchAppleSubscriptionStatus(productId: syncProductId)
                }
                let appleStatus = result?.status ?? 1
                let expirationDate = result?.expirationDate
                ZSLogger.info("[MigrationTip] Syncing Apple status=\(appleStatus == 1 ? "active" : "cancelled") for \(syncProductId) to backend", category: .migration)
                await self.syncStorekitStatusToBackend(productId: syncProductId, status: appleStatus, expirationDate: expirationDate)

                // If Apple is cancelled and we're in .accepted, transition to .completed
                if appleStatus == 2 && self.state == .accepted {
                    self.storekitCancelRequired = false
                    self.state = .completed
                    ZSLogger.info("[MigrationTip] COMPLETED: Apple cancelled — .accepted → .completed", category: .migration)
                }
            }
        }

        // ── Check 1: Mid-flow lock ──
        guard state == .loading || state == .ineligible || state == .eligible else {
            ZSLogger.info("[MigrationTip] SKIP: mid-flow locked (state=.\(state))", category: .migration)
            return
        }

        // ── Check 2: SDK bootstrapped ──
        guard iap.isBootstrapped else {
            state = .loading
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: SDK not bootstrapped yet", category: .migration)
            return
        }

        // ── Check 3: Demo mode (bypasses all real checks) ──
        if Self.demoMode {
            let prompt = MigrationPrompt(
                productId: "wizzGoldWeekly",
                discountPercent: 15,
                title: "Switch & Save",
                message: "Switch to direct billing and get 15% off forever. Same features, fewer platform fees, and we pass the savings onto you.",
                ctaText: "Save 15% Forever"
            )
            state = .eligible
            offerData = MigrationOffer.OfferData(
                prompt: prompt, freeTrialDays: 7,
                activeStoreKitProductId: "wizzGoldWeekly",
                activeStoreKitExpiresAt: nil, activeStoreKitOriginalTransactionId: nil
            )
            ZSLogger.info("[MigrationTip] SHOW: demo mode", category: .migration)
            return
        }

        // ── Check 4: Not permanently dismissed ──
        guard !Self.isPermanentlyDismissed else {
            state = .dismissed
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: permanently dismissed", category: .migration)
            return
        }

        // ── Gather entitlements ──
        let storeKitEntitlements = iap.entitlements.filter { $0.source == .storeKit }
        let activeStoreKitEntitlements = storeKitEntitlements.filter { $0.isActive }
        let webEntitlements = iap.entitlements.filter { $0.source == .webCheckout }
        let activeWebEntitlements = webEntitlements.filter { $0.isActive }

        ZSLogger.info("[MigrationTip] Entitlements: storeKit=\(storeKitEntitlements.count) (active=\(activeStoreKitEntitlements.count)), web=\(webEntitlements.count) (active=\(activeWebEntitlements.count))", category: .migration)
        for ent in iap.entitlements {
            ZSLogger.info("[MigrationTip]   \(ent.source.rawValue): \(ent.productId) active=\(ent.isActive) status=\(ent.status.rawString) willRenew=\(ent.willRenew) expires=\(ent.expiresAt?.description ?? "nil") origTxnId=\(ent.storekitOriginalTransactionId ?? "nil") originalPurchase=\(ent.originalPurchaseDate?.description ?? "nil")", category: .migration)
        }

        // ── Check 5: Has active StoreKit subscription ──
        guard !activeStoreKitEntitlements.isEmpty else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: no active StoreKit subscription", category: .migration)
            return
        }

        // ── Check 6: Both StoreKit + web active ──
        if !activeWebEntitlements.isEmpty && !activeStoreKitEntitlements.isEmpty {
            let appleWillRenew = activeStoreKitEntitlements.first?.willRenew ?? true
            if appleWillRenew {
                // Apple still renewing → prompt user to cancel
                storekitCancelRequired = true
                state = .accepted
                ZSLogger.info("[MigrationTip] CANCEL_REQUIRED: Apple subscription still renewing — prompting cancellation", category: .migration)
            } else {
                // Apple already cancelled → migration complete
                storekitCancelRequired = false
                state = .completed
                ZSLogger.info("[MigrationTip] COMPLETED: Apple subscription already cancelled (willRenew=false)", category: .migration)
            }
            return
        }

        // ── Check 7: Web-only active → already migrated, no tip needed ──
        guard activeWebEntitlements.isEmpty else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: active web entitlement exists, no active StoreKit (already migrated)", category: .migration)
            return
        }

        // ── Check 8: Migration prompt resolved from backend or sandbox ──
        guard let resolved = resolveMigrationPrompt(activeStoreKitEntitlements: activeStoreKitEntitlements) else {
            state = .ineligible
            offerData = nil
            let migration = iap.remoteConfig?.migration
            ZSLogger.info("[MigrationTip] SKIP: no migration prompt (config=\(migration != nil ? "present" : "nil"), eligible=\(migration?.eligibleProductIds ?? []), active=\(activeStoreKitEntitlements.map { $0.productId }), sandbox=\(iap.isSandbox))", category: .migration)
            return
        }

        let prompt = resolved.prompt
        let matchedEntitlement = resolved.matchedEntitlement

        // ── Check 9: Subscription tenure within subscription window ──
        if prompt.minSubscriptionDays > 0 || prompt.maxSubscriptionDays != nil {
            let tenureDays: Int
            if let originalDate = matchedEntitlement.originalPurchaseDate {
                tenureDays = Calendar.current.dateComponents([.day], from: originalDate, to: Date()).day ?? 0
            } else {
                // Fall back to purchasedAt (current period) if originalPurchaseDate unavailable
                tenureDays = Calendar.current.dateComponents([.day], from: matchedEntitlement.purchasedAt, to: Date()).day ?? 0
            }
            ZSLogger.info("[MigrationTip] Subscription tenure: \(tenureDays) days (original=\(matchedEntitlement.originalPurchaseDate?.description ?? "nil"), window=\(prompt.minSubscriptionDays)-\(prompt.maxSubscriptionDays.map(String.init) ?? "∞")d)", category: .migration)

            if tenureDays < prompt.minSubscriptionDays {
                state = .ineligible
                offerData = nil
                ZSLogger.info("[MigrationTip] SKIP: subscription tenure \(tenureDays)d < minSubscriptionDays \(prompt.minSubscriptionDays)d", category: .migration)
                return
            }
            if let maxDays = prompt.maxSubscriptionDays, tenureDays > maxDays {
                state = .ineligible
                offerData = nil
                ZSLogger.info("[MigrationTip] SKIP: subscription tenure \(tenureDays)d > maxSubscriptionDays \(maxDays)d", category: .migration)
                return
            }
        }

        // ── Check 10: Target product exists in catalog ──
        let catalogProducts = iap.products
        guard let targetProduct = catalogProducts.first(where: { $0.id == prompt.productId }) else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: migration target '\(prompt.productId)' not in catalog (available: \(catalogProducts.map { $0.id }))", category: .migration)
            return
        }

        // ── All checks passed → eligible ──
        let data = MigrationOffer.OfferData(
            prompt: prompt,
            freeTrialDays: prompt.freeTrialDays,
            activeStoreKitProductId: matchedEntitlement.productId,
            activeStoreKitExpiresAt: matchedEntitlement.expiresAt,
            activeStoreKitOriginalTransactionId: matchedEntitlement.storekitOriginalTransactionId
        )
        state = .eligible
        offerData = data

        let source = iap.remoteConfig?.migration != nil ? "backend" : "sandbox"
        if let webPrice = targetProduct.webPrice, let skPrice = targetProduct.storeKitPrice {
            ZSLogger.info("[MigrationTip] SHOW: \(matchedEntitlement.productId) → \(prompt.productId), discount=\(prompt.discountPercent)%, freeTrialDays=\(prompt.freeTrialDays), price: \(skPrice.formatted) → \(webPrice.formatted), source=\(source)", category: .migration)
        } else {
            ZSLogger.info("[MigrationTip] SHOW: \(matchedEntitlement.productId) → \(prompt.productId), discount=\(prompt.discountPercent)%, freeTrialDays=\(prompt.freeTrialDays), source=\(source)", category: .migration)
        }
    }

    /// Resolves the migration prompt from backend config or synthesizes one in sandbox mode.
    /// Matches the user's active StoreKit entitlements against the prompt's eligible product IDs.
    /// - Returns: A tuple of the resolved prompt (with `productId` set to the matched product)
    ///   and the matched entitlement, or `nil` if no match is found.
    private func resolveMigrationPrompt(activeStoreKitEntitlements: [Entitlement]) -> (prompt: MigrationPrompt, matchedEntitlement: Entitlement)? {
        let iap = ZeroSettle.shared

        // Use backend-provided prompt if available
        if let backendPrompt = iap.remoteConfig?.migration {
            ZSLogger.debug("[MigrationManager] Backend migration prompt: productId=\(backendPrompt.productId), eligibleProductIds=\(backendPrompt.eligibleProductIds), discount=\(backendPrompt.discountPercent)%", category: .migration)

            // Find the first active StoreKit entitlement whose productId is in the eligible list
            guard let matchedEntitlement = activeStoreKitEntitlements.first(where: { backendPrompt.eligibleProductIds.contains($0.productId) }) else {
                ZSLogger.debug("[MigrationManager] No match — active StoreKit products \(activeStoreKitEntitlements.map { $0.productId }) not in eligible list \(backendPrompt.eligibleProductIds)", category: .migration)
                return nil
            }

            // Build a prompt with productId set to the matched entitlement's product,
            // using per-product data when available for accurate discount/text
            let resolvedPrompt: MigrationPrompt
            if let perProduct = backendPrompt.perProductPrompts?[matchedEntitlement.productId] {
                resolvedPrompt = MigrationPrompt(
                    productId: matchedEntitlement.productId,
                    eligibleProductIds: backendPrompt.eligibleProductIds,
                    discountPercent: perProduct.discountPercent,
                    freeTrialDays: backendPrompt.freeTrialDays,
                    title: perProduct.title,
                    message: perProduct.message,
                    ctaText: perProduct.ctaText,
                    perProductPrompts: backendPrompt.perProductPrompts
                )
            } else {
                resolvedPrompt = MigrationPrompt(
                    productId: matchedEntitlement.productId,
                    eligibleProductIds: backendPrompt.eligibleProductIds,
                    discountPercent: backendPrompt.discountPercent,
                    freeTrialDays: backendPrompt.freeTrialDays,
                    title: backendPrompt.title,
                    message: backendPrompt.message,
                    ctaText: backendPrompt.ctaText,
                    perProductPrompts: backendPrompt.perProductPrompts
                )
            }
            ZSLogger.debug("[MigrationManager] Matched StoreKit product '\(matchedEntitlement.productId)' from eligible list", category: .migration)
            return (resolvedPrompt, matchedEntitlement)
        }

        // In sandbox mode, synthesize a prompt so developers can always test the flow
        if iap.isSandbox {
            guard let firstEntitlement = activeStoreKitEntitlements.first else { return nil }
            ZSLogger.debug("[MigrationManager] Sandbox mode — synthesizing migration prompt for productId=\(firstEntitlement.productId)", category: .migration)
            let prompt = MigrationPrompt(
                productId: firstEntitlement.productId,
                discountPercent: 15,
                title: "Switch & Save",
                message: "Switch to direct billing and get 15% off forever. Same features, fewer platform fees.",
                ctaText: "Save 15% Forever"
            )
            return (prompt, firstEntitlement)
        }

        ZSLogger.debug("[MigrationManager] No migration prompt: backend migration=nil, isSandbox=false", category: .migration)
        return nil
    }

    /// Computes the number of free trial days from a StoreKit entitlement's expiration date.
    private func computeFreeTrialDays(from entitlement: Entitlement) -> Int {
        guard let expiresAt = entitlement.expiresAt else {
            ZSLogger.debug("[MigrationManager] No expiresAt on entitlement \(entitlement.productId), freeTrialDays=0", category: .migration)
            return 0
        }
        let components = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt)
        let days = max(0, components.day ?? 0)
        ZSLogger.debug("[MigrationManager] Computed freeTrialDays=\(days) (expiresAt=\(expiresAt))", category: .migration)
        return days
    }

    // MARK: - State Transitions

    /// Transition from `.eligible` to `.presented`.
    ///
    /// Call this when you show the migration offer UI or begin the checkout flow.
    public func present() {
        guard state == .eligible else {
            ZSLogger.info("[MigrationManager] present() ignored — state is .\(state), expected .eligible", category: .migration)
            return
        }
        state = .presented
        ZSLogger.info("[MigrationManager] .eligible → .presented", category: .migration)
    }

    /// Create a payment intent and return the checkout URL.
    ///
    /// Transitions to `.presented` if not already there.
    /// Returns `nil` if checkout creation fails (check ``checkoutError``).
    ///
    /// - Returns: The checkout URL to load in a webview, or `nil` on failure
    @discardableResult
    public func startCheckout() async -> URL? {
        guard let offerData else {
            ZSLogger.error("[MigrationManager] startCheckout() failed — no offerData available", category: .migration)
            checkoutError = ZeroSettleError.notConfigured
            return nil
        }

        if state == .eligible {
            state = .presented
            ZSLogger.info("[MigrationManager] .eligible → .presented (via startCheckout)", category: .migration)
        }

        checkoutError = nil
        isLoading = true

        ZSLogger.info("[MigrationManager] Creating payment intent: productId=\(offerData.prompt.productId), userId=\(userId), stripeCustomerId=\(stripeCustomerId ?? "nil"), freeTrialDays=\(offerData.freeTrialDays), activeStoreKitProductId=\(offerData.activeStoreKitProductId), activeStoreKitExpiresAt=\(offerData.activeStoreKitExpiresAt?.description ?? "nil"), discount=\(offerData.prompt.discountPercent)%", category: .migration)

        // Log the Stripe product mapping being used for checkout
        let catalogProducts = ZeroSettle.shared.products
        if let targetProduct = catalogProducts.first(where: { $0.id == offerData.prompt.productId }) {
            ZSLogger.info("[MigrationManager] Checkout product details: displayName=\"\(targetProduct.displayName)\", type=\(targetProduct.type.rawValue), webPrice=\(targetProduct.webPrice.map { "\($0.formatted) (\($0.amountCents)¢ \($0.currencyCode))" } ?? "nil"), storeKitPrice=\(targetProduct.storeKitPrice.map { "\($0.formatted)" } ?? "nil")", category: .migration)
        } else {
            ZSLogger.info("[MigrationManager] ⚠️ Checkout product '\(offerData.prompt.productId)' not found in current catalog (\(catalogProducts.count) products)", category: .migration)
        }

        do {
            let backend = try makeBackend()

            if let baseURL = ZeroSettle.shared.effectiveBaseURL {
                let paymentIntentsURL = baseURL.appendingPathComponent("iap/payment-intents/")
                ZSLogger.info("[MigrationManager] Stripe payment intents URL: \(paymentIntentsURL.absoluteString)", category: .migration)
            }

            let paymentIntent = try await backend.createPaymentIntent(
                productId: offerData.prompt.productId,
                userId: userId,
                freeTrialDays: offerData.freeTrialDays,
                stripeCustomerId: stripeCustomerId,
                storekitSubscriptionEnd: offerData.activeStoreKitExpiresAt,
                storekitOriginalTransactionId: offerData.activeStoreKitOriginalTransactionId
            )

            isLoading = false
            checkoutTransactionId = paymentIntent.transactionId
            let url = URL(string: paymentIntent.checkoutUrl)
            ZSLogger.info("[MigrationManager] Migration checkout created — transactionId=\(paymentIntent.transactionId), checkoutUrl=\(paymentIntent.checkoutUrl), storekitSubscriptionEnd=\(offerData.activeStoreKitExpiresAt?.description ?? "nil"), originalTransactionId=\(offerData.activeStoreKitOriginalTransactionId ?? "nil")", category: .migration)

            // Default Apple subscription to active — "guilty until proven innocent".
            // Updated with real status after manage subscription sheet dismisses.
            do {
                try await backend.updateStorekitStatus(transactionId: paymentIntent.transactionId, storekitStatus: 1)
                ZSLogger.info("[MigrationManager] Set default storekit_status=1 (active) on transaction=\(paymentIntent.transactionId)", category: .migration)
            } catch {
                ZSLogger.error("[MigrationManager] Failed to set default storekit_status: \(error)", category: .migration)
            }

            return url
        } catch {
            checkoutError = error
            isLoading = false
            ZSLogger.error("[MigrationManager] Payment intent failed: \(error)", category: .migration)

            // If the product doesn't exist on the backend, the migration offer is invalid —
            // hide the view by transitioning to .ineligible.
            if case .apiError(let detail) = error as? ZeroSettleError, detail.statusCode == 404 {
                state = .ineligible
                self.offerData = nil
                ZSLogger.info("[MigrationManager] .presented → .ineligible — product not found on backend (404)", category: .migration)
            }

            return nil
        }
    }

    /// Mark the web checkout as succeeded.
    ///
    /// Transitions from `.presented` to `.accepted`, verifies the transaction with the
    /// backend, refreshes entitlements, fires delegate events, and tracks migration conversion.
    ///
    /// - Parameter transactionId: The transaction ID returned by the checkout page.
    ///   When provided, the backend is polled to verify payment and entitlements are refreshed.
    public func markCheckoutSucceeded(transactionId: String? = nil) async {
        guard state == .presented else {
            ZSLogger.info("[MigrationManager] markCheckoutSucceeded() ignored — state is .\(state), expected .presented", category: .migration)
            return
        }
        state = .accepted
        ZSLogger.info("[MigrationManager] .presented → .accepted — checkout succeeded for userId=\(userId), transactionId=\(transactionId ?? "nil")", category: .migration)

        // Verify transaction and refresh entitlements (matches ZSPaymentSheet pattern)
        if let transactionId {
            do {
                let backend = try makeBackend()
                let transaction = try await backend.verifyTransaction(transactionId: transactionId)
                ZSLogger.info("[MigrationManager] Migration transaction verified: \(transaction.id) for \(transaction.productId)", category: .migration)
                await ZeroSettle.shared.delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                await ZeroSettle.shared.refreshEntitlementsAfterCheckout(transaction: transaction)
            } catch {
                ZSLogger.error("[MigrationManager] Migration transaction verification failed: \(error)", category: .migration)
            }
        } else {
            ZSLogger.info("[MigrationManager] No transactionId provided — skipping verification (entitlements will sync on next refresh)", category: .migration)
        }

        // Fire-and-forget conversion tracking
        Task {
            ZSLogger.info("[MigrationManager] Tracking migration conversion for userId=\(userId)", category: .migration)
            do {
                try await ZeroSettle.shared.trackMigrationConversion(userId: userId)
                ZSLogger.info("[MigrationManager] Migration conversion tracked successfully", category: .migration)
            } catch {
                ZSLogger.error("[MigrationManager] Migration conversion tracking failed: \(error)", category: .migration)
            }
        }
    }

    /// Open the Apple subscription management sheet.
    ///
    /// After the sheet dismisses, queries the server-side Apple endpoint for real-time
    /// cancellation status. If cancelled, transitions to `.completed`. If still active,
    /// stays in `.accepted` with ``storekitCancelRequired`` set. Falls back to on-device
    /// StoreKit if the server call fails.
    public func showAppleSubscriptionManagement() async {
        guard state == .accepted else {
            ZSLogger.info("[MigrationManager] showAppleSubscriptionManagement() ignored — state is .\(state), expected .accepted", category: .migration)
            return
        }

        ZSLogger.info("[MigrationManager] Opening Apple subscription management sheet...", category: .migration)

        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                ZSLogger.error("[MigrationManager] No UIWindowScene available — cannot open subscription management", category: .migration)
                return
            }
            try await AppStore.showManageSubscriptions(in: windowScene)
        } catch {
            ZSLogger.error("[MigrationManager] Failed to open subscription management: \(error)", category: .migration)
            return
        }

        // Sheet dismissed — verify cancellation via server-side Apple API (real-time)
        let productId = offerData?.activeStoreKitProductId
            ?? ZeroSettle.shared.entitlements.first(where: { $0.source == .storeKit && $0.isActive })?.productId
        let origTxnId = offerData?.activeStoreKitOriginalTransactionId
            ?? ZeroSettle.shared.entitlements.first(where: { $0.source == .storeKit && $0.isActive })?.storekitOriginalTransactionId
        let txnId = checkoutTransactionId

        // Try server-side first (real-time), fall back to on-device StoreKit
        var result = await fetchAppleSubscriptionStatusFromServer(originalTransactionId: origTxnId)
        if result == nil {
            result = await fetchAppleSubscriptionStatus(productId: productId)
        }
        let appleStatus = result?.status ?? 1
        let expirationDate = result?.expirationDate
        ZSLogger.info("[MigrationManager] Post-dismiss verification: Apple status=\(appleStatus == 1 ? "active" : "cancelled") for product=\(productId ?? "nil")", category: .migration)

        if appleStatus == 2 {
            // Confirmed cancelled
            storekitCancelRequired = false
            state = .completed
            ZSLogger.info("[MigrationManager] .accepted → .completed (verified cancelled)", category: .migration)
        } else {
            // Still active — user didn't cancel
            storekitCancelRequired = true
            ZSLogger.info("[MigrationManager] Subscription still active after manage sheet — storekitCancelRequired=true", category: .migration)
        }

        // Sync status to backend
        if let txnId {
            do {
                let backend = try makeBackend()
                try await backend.updateStorekitStatus(transactionId: txnId, storekitStatus: appleStatus, storekitSubscriptionEnd: expirationDate)
                ZSLogger.info("[MigrationManager] Backend updated storekit_status=\(appleStatus) on transaction=\(txnId)", category: .migration)
            } catch {
                ZSLogger.error("[MigrationManager] Failed to update backend: \(error)", category: .migration)
            }
        }
    }

    /// Query the server for real-time Apple subscription status (bypasses on-device StoreKit cache).
    /// Returns the same tuple as fetchAppleSubscriptionStatus, or nil on failure.
    private func fetchAppleSubscriptionStatusFromServer(originalTransactionId: String?) async -> (status: Int, expirationDate: Date?)? {
        guard let originalTransactionId else {
            ZSLogger.info("[MigrationManager] fetchAppleSubscriptionStatusFromServer — originalTransactionId is nil", category: .migration)
            return nil
        }

        do {
            let backend = try makeBackend()
            let response = try await backend.getStoreKitSubscriptionStatus(originalTransactionId: originalTransactionId)
            ZSLogger.info("[MigrationManager] Server subscription status: status=\(response.status), autoRenew=\(response.autoRenewStatus), expires=\(response.expiresAt?.description ?? "nil")", category: .migration)
            return (response.status, response.expiresAt)
        } catch {
            ZSLogger.info("[MigrationManager] Server subscription status failed, will fall back to on-device: \(error)", category: .migration)
            return nil
        }
    }

    /// Query StoreKit for the Apple subscription status.
    /// Returns a tuple of (status, expirationDate) where status is 1 (active) or 2 (cancelled), or nil if unknown.
    /// Active = subscribed + willAutoRenew. Everything else = cancelled.
    private func fetchAppleSubscriptionStatus(productId: String?) async -> (status: Int, expirationDate: Date?)? {
        guard let productId else {
            ZSLogger.info("[MigrationManager] fetchAppleSubscriptionStatus — productId is nil", category: .migration)
            return nil
        }

        guard let product = try? await Product.products(for: [productId]).first,
              let subscription = product.subscription else {
            ZSLogger.info("[MigrationManager] No subscription info found for product=\(productId)", category: .migration)
            return nil
        }

        guard let statuses = try? await subscription.status,
              let status = statuses.first else {
            ZSLogger.info("[MigrationManager] No subscription status entries for product=\(productId)", category: .migration)
            return nil
        }

        var willAutoRenew = false
        if case .verified(let renewalInfo) = status.renewalInfo {
            willAutoRenew = renewalInfo.willAutoRenew
        }

        var expirationDate: Date? = nil
        if case .verified(let transaction) = status.transaction {
            expirationDate = transaction.expirationDate
        }

        let isActive = status.state == .subscribed && willAutoRenew
        ZSLogger.info("[MigrationManager] Apple subscription: state=\(status.state), willAutoRenew=\(willAutoRenew), expirationDate=\(expirationDate?.description ?? "nil") → \(isActive ? "active" : "cancelled")", category: .migration)
        return (isActive ? 1 : 2, expirationDate)
    }

    /// Syncs the StoreKit subscription status to the backend.
    /// Fetches transaction history by userId, finds the matching web checkout transaction
    /// for the given product, and updates its storekit_status.
    private func syncStorekitStatusToBackend(productId: String?, status: Int, expirationDate: Date? = nil) async {
        ZSLogger.info("[MigrationManager] syncStorekitStatusToBackend — userId=\(userId), productId=\(productId ?? "nil"), status=\(status == 1 ? "active" : "cancelled"), expirationDate=\(expirationDate?.description ?? "nil")", category: .migration)
        do {
            let backend = try makeBackend()
            let transactions = try await backend.getTransactionHistory(userId: userId)
            ZSLogger.info("[MigrationManager] Fetched \(transactions.count) transaction(s) for userId=\(userId)", category: .migration)

            let matchingTxn = transactions.first { txn in
                txn.source == .webCheckout && txn.status == .completed && (productId == nil || txn.productId == productId)
            }

            if let txn = matchingTxn {
                ZSLogger.info("[MigrationManager] Found transaction=\(txn.id), updating Apple status to \(status == 1 ? "active" : "cancelled")", category: .migration)
                try await backend.updateStorekitStatus(transactionId: txn.id, storekitStatus: status, storekitSubscriptionEnd: expirationDate)
                checkoutTransactionId = txn.id
                ZSLogger.info("[MigrationManager] ✅ Updated Apple status=\(status == 1 ? "active" : "cancelled") on transaction=\(txn.id)", category: .migration)
            } else {
                ZSLogger.info("[MigrationManager] No matching web checkout transaction found for productId=\(productId ?? "nil")", category: .migration)
            }
        } catch {
            ZSLogger.error("[MigrationManager] ❌ Failed to sync Apple status to backend: \(error)", category: .migration)
        }
    }

    /// Dismiss the migration offer.
    ///
    /// Sets the state to `.dismissed` and persists the dismissal in UserDefaults.
    /// Can be called from any state.
    public func dismiss() {
        let previous = state
        state = .dismissed
        offerData = nil
        Self.isPermanentlyDismissed = true
        ZSLogger.info("[MigrationManager] .\(previous) → .dismissed — persisted to UserDefaults", category: .migration)
    }

    // MARK: - Backend Helper

    private func makeBackend() throws -> Backend {
        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            ZSLogger.error("[MigrationManager] makeBackend() failed — SDK not configured", category: .migration)
            throw ZeroSettleError.notConfigured
        }
        return Backend(baseURL: baseURL, publishableKey: config.publishableKey)
    }
}
