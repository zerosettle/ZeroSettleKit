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

    /// Re-evaluates eligibility. Only runs when state is `.ineligible` or `.eligible`
    /// (mid-flow states are locked to prevent disruption).
    private func evaluateEligibility() {
        // Demo mode: force out of dismissed state so re-evaluation can proceed
        if Self.demoMode && state == .dismissed {
            ZSLogger.info("[MigrationManager] Demo mode — resetting dismissed state", category: .migration)
            state = .loading
        }

        let previousState = state

        // Don't re-evaluate during active flow
        guard state == .loading || state == .ineligible || state == .eligible else {
            ZSLogger.debug("[MigrationManager] evaluateEligibility() skipped — state is .\(state) (mid-flow locked)", category: .migration)
            return
        }

        let iap = ZeroSettle.shared

        ZSLogger.info("[MigrationManager] evaluateEligibility() running — currentState=.\(state), isBootstrapped=\(iap.isBootstrapped), isConfigured=\(iap.isConfigured), isPermanentlyDismissed=\(Self.isPermanentlyDismissed), isSandbox=\(iap.isSandbox), demoMode=\(Self.demoMode)", category: .migration)

        // Must be bootstrapped — stay in .loading until bootstrap completes
        guard iap.isBootstrapped else {
            state = .loading
            offerData = nil
            ZSLogger.info("[MigrationManager] → .loading — waiting for bootstrap", category: .migration)
            return
        }

        // Demo mode: skip dismissal check, entitlement checks, and synthesize a demo offer
        if Self.demoMode {
            ZSLogger.info("[MigrationManager] 🎭 Demo mode active — skipping dismissal and entitlement checks", category: .migration)

            let prompt = MigrationPrompt(
                productId: "wizzGoldWeekly",
                discountPercent: 15,
                title: "Switch & Save",
                message: "Switch to direct billing and get 15% off forever. Same features, fewer platform fees, and we pass the savings onto you.",
                ctaText: "Save 15% Forever"
            )

            let data = MigrationOffer.OfferData(
                prompt: prompt,
                freeTrialDays: 7,
                activeStoreKitProductId: "wizzGoldWeekly",
                activeStoreKitExpiresAt: nil
            )

            state = .eligible
            offerData = data
            ZSLogger.info("[MigrationManager] .\(previousState) → .eligible — demo mode (productId=wizzGoldWeekly, discount=15%, freeTrialDays=7)", category: .migration)
            return
        }

        // Must not be permanently dismissed
        guard !Self.isPermanentlyDismissed else {
            let changed = state != .dismissed
            state = .dismissed
            offerData = nil
            ZSLogger.info("[MigrationManager] → .dismissed — permanently dismissed via UserDefaults\(changed ? "" : " (already dismissed)")", category: .migration)
            return
        }

        // ── Full entitlement snapshot ──
        let entitlementSummary = iap.entitlements.map {
            "[\($0.productId) source=\($0.source.rawValue) active=\($0.isActive) status=\($0.status.rawString) willRenew=\($0.willRenew) isTrial=\($0.isTrial) expires=\($0.expiresAt?.description ?? "nil") cancelledAt=\($0.cancelledAt?.description ?? "nil") purchasedAt=\($0.purchasedAt.description)]"
        }.joined(separator: "\n  ")
        ZSLogger.info("[MigrationManager] Entitlements (\(iap.entitlements.count)):\n  \(entitlementSummary.isEmpty ? "(none)" : entitlementSummary)", category: .migration)

        // ── Separate entitlements by source for clarity ──
        let storeKitEntitlements = iap.entitlements.filter { $0.source == .storeKit }
        let activeStoreKitEntitlements = storeKitEntitlements.filter { $0.isActive }
        let inactiveStoreKitEntitlements = storeKitEntitlements.filter { !$0.isActive }
        ZSLogger.info("[MigrationManager] StoreKit entitlements: \(storeKitEntitlements.count) total, \(activeStoreKitEntitlements.count) active, \(inactiveStoreKitEntitlements.count) inactive", category: .migration)
        for ent in storeKitEntitlements {
            ZSLogger.info("[MigrationManager]   StoreKit entitlement: productId=\(ent.productId), active=\(ent.isActive), status=\(ent.status.rawString), willRenew=\(ent.willRenew), isTrial=\(ent.isTrial), expires=\(ent.expiresAt?.description ?? "nil"), cancelledAt=\(ent.cancelledAt?.description ?? "nil")", category: .migration)
        }

        // Must have at least one active StoreKit subscription
        guard !activeStoreKitEntitlements.isEmpty else {
            state = .ineligible
            offerData = nil
            if storeKitEntitlements.isEmpty {
                ZSLogger.info("[MigrationManager] → .ineligible — no StoreKit entitlements at all (user has never subscribed via App Store)", category: .migration)
            } else {
                ZSLogger.info("[MigrationManager] → .ineligible — found \(storeKitEntitlements.count) StoreKit entitlement(s) but none are active: \(inactiveStoreKitEntitlements.map { "\($0.productId)(status=\($0.status.rawString))" })", category: .migration)
            }
            return
        }
        ZSLogger.info("[MigrationManager] ✅ Active StoreKit subscription(s) found: \(activeStoreKitEntitlements.map { "\($0.productId)(status=\($0.status.rawString), willRenew=\($0.willRenew))" })", category: .migration)

        // ── Log the product catalog mapping for active subscriptions ──
        let catalogProducts = iap.products
        ZSLogger.info("[MigrationManager] Product catalog has \(catalogProducts.count) product(s)", category: .migration)
        for activeEnt in activeStoreKitEntitlements {
            if let matchingProduct = catalogProducts.first(where: { $0.id == activeEnt.productId }) {
                ZSLogger.info("[MigrationManager] Catalog match for active subscription '\(activeEnt.productId)': displayName=\"\(matchingProduct.displayName)\", type=\(matchingProduct.type.rawValue), webPrice=\(matchingProduct.webPrice.map { "\($0.formatted) (\($0.amountCents)¢ \($0.currencyCode))" } ?? "nil"), appStorePrice=\(matchingProduct.appStorePrice.map { "\($0.formatted) (\($0.amountCents)¢ \($0.currencyCode))" } ?? "nil"), storeKitAvailable=\(matchingProduct.storeKitAvailable), storeKitPrice=\(matchingProduct.storeKitPrice.map { "\($0.formatted) (\($0.amountCents)¢ \($0.currencyCode))" } ?? "nil"), syncedToAsc=\(matchingProduct.syncedToAppStoreConnect), savingsPercent=\(matchingProduct.savingsPercent.map(String.init) ?? "nil"), subscriptionGroupId=\(matchingProduct.subscriptionGroupId.map(String.init) ?? "nil")", category: .migration)
            } else {
                ZSLogger.info("[MigrationManager] ⚠️ No catalog product found for active StoreKit subscription '\(activeEnt.productId)' — available product IDs: \(catalogProducts.map { $0.id })", category: .migration)
            }
        }

        // ── Web entitlement check ──
        let webEntitlements = iap.entitlements.filter { $0.source == .webCheckout }
        let activeWebEntitlements = webEntitlements.filter { $0.isActive }
        ZSLogger.info("[MigrationManager] Web entitlements: \(webEntitlements.count) total, \(activeWebEntitlements.count) active", category: .migration)
        for ent in webEntitlements {
            ZSLogger.info("[MigrationManager]   Web entitlement: productId=\(ent.productId), active=\(ent.isActive), status=\(ent.status.rawString), expires=\(ent.expiresAt?.description ?? "nil")", category: .migration)
        }

        guard activeWebEntitlements.isEmpty else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationManager] → .ineligible — user already has active web checkout entitlement(s): \(activeWebEntitlements.map { "\($0.productId)(status=\($0.status.rawString), expires=\($0.expiresAt?.description ?? "nil"))" })", category: .migration)
            return
        }

        // ── Resolve migration prompt ──
        let backendMigration = iap.remoteConfig?.migration
        ZSLogger.info("[MigrationManager] remoteConfig.migration=\(backendMigration != nil ? "present(productId=\(backendMigration!.productId), eligibleProductIds=\(backendMigration!.eligibleProductIds), discount=\(backendMigration!.discountPercent)%, title=\"\(backendMigration!.title)\", message=\"\(backendMigration!.message)\", ctaText=\"\(backendMigration!.ctaText)\")" : "nil"), isSandbox=\(iap.isSandbox)", category: .migration)

        guard let resolved = resolveMigrationPrompt(
            activeStoreKitEntitlements: activeStoreKitEntitlements
        ) else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationManager] → .ineligible — no migration prompt resolved (backend migration=\(backendMigration != nil ? "present, eligible=\(backendMigration!.eligibleProductIds)" : "nil"), activeProducts=\(activeStoreKitEntitlements.map { $0.productId }), isSandbox=\(iap.isSandbox))", category: .migration)
            return
        }

        let prompt = resolved.prompt
        let matchedEntitlement = resolved.matchedEntitlement

        // ── Log the Stripe product mapping for the migration target product ──
        ZSLogger.info("[MigrationManager] Migration prompt resolved — matched StoreKit product '\(matchedEntitlement.productId)' from eligible list \(prompt.eligibleProductIds), discount=\(prompt.discountPercent)%, title=\"\(prompt.title)\", ctaText=\"\(prompt.ctaText)\"", category: .migration)
        if let targetProduct = catalogProducts.first(where: { $0.id == prompt.productId }) {
            ZSLogger.info("[MigrationManager] Stripe product mapping for migration target '\(prompt.productId)': displayName=\"\(targetProduct.displayName)\", type=\(targetProduct.type.rawValue), webPrice=\(targetProduct.webPrice.map { "\($0.formatted) (\($0.amountCents)¢ \($0.currencyCode))" } ?? "nil"), appStorePrice=\(targetProduct.appStorePrice.map { "\($0.formatted) (\($0.amountCents)¢ \($0.currencyCode))" } ?? "nil"), storeKitAvailable=\(targetProduct.storeKitAvailable), syncedToAsc=\(targetProduct.syncedToAppStoreConnect), subscriptionGroupId=\(targetProduct.subscriptionGroupId.map(String.init) ?? "nil")", category: .migration)
            if let webPrice = targetProduct.webPrice, let skPrice = targetProduct.storeKitPrice {
                let priceDiff = skPrice.amountCents - webPrice.amountCents
                ZSLogger.info("[MigrationManager] Price comparison: StoreKit=\(skPrice.formatted) vs Web=\(webPrice.formatted), savings=\(priceDiff)¢ (\(targetProduct.savingsPercent.map { "\($0)%" } ?? "N/A"))", category: .migration)
            }
        } else {
            ZSLogger.info("[MigrationManager] ⚠️ Migration target product '\(prompt.productId)' not found in catalog — available product IDs: \(catalogProducts.map { $0.id })", category: .migration)
            state = .ineligible
            offerData = nil
            return
        }

        // Use backend-provided free trial days (approximate remaining StoreKit period).
        // The precise trial_end is resolved server-side at checkout time via Apple's API.
        let freeTrialDays = prompt.freeTrialDays
        ZSLogger.info("Using freeTrialDays=\(freeTrialDays) from migration config", category: .migration)

        let data = MigrationOffer.OfferData(
            prompt: prompt,
            freeTrialDays: freeTrialDays,
            activeStoreKitProductId: matchedEntitlement.productId,
            activeStoreKitExpiresAt: matchedEntitlement.expiresAt
        )

        state = .eligible
        offerData = data

        let promptSource = iap.remoteConfig?.migration != nil ? "backend" : "sandbox"
        ZSLogger.info("[MigrationManager] .\(previousState) → .eligible — matchedStoreKitProductId=\(matchedEntitlement.productId), migrationTargetProductId=\(prompt.productId), eligibleProductIds=\(prompt.eligibleProductIds), discount=\(prompt.discountPercent)%, freeTrialDays=\(freeTrialDays), promptSource=\(promptSource), title=\"\(prompt.title)\"", category: .migration)
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

        ZSLogger.info("[MigrationManager] Creating payment intent: productId=\(offerData.prompt.productId), userId=\(userId), stripeCustomerId=\(stripeCustomerId ?? "nil"), freeTrialDays=\(offerData.freeTrialDays), activeStoreKitProductId=\(offerData.activeStoreKitProductId), discount=\(offerData.prompt.discountPercent)%", category: .migration)

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
                storekitSubscriptionEnd: offerData.activeStoreKitExpiresAt
            )

            isLoading = false
            let url = URL(string: paymentIntent.checkoutUrl)
            ZSLogger.info("[MigrationManager] Payment intent created — checkoutUrl=\(paymentIntent.checkoutUrl)", category: .migration)
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

    /// Open the Apple subscription management sheet, then transition to `.completed`.
    ///
    /// After the sheet dismisses, the state moves to `.completed` to indicate the
    /// full migration flow is done.
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
            state = .completed
            ZSLogger.info("[MigrationManager] .accepted → .completed — subscription management sheet dismissed", category: .migration)
        } catch {
            ZSLogger.error("[MigrationManager] Failed to open subscription management: \(error)", category: .migration)
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
