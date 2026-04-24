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
import CryptoKit

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
@available(*, deprecated, message: "Use ZSOfferManager — a strict superset that supports migration, StoreKit→web upgrades, and web→web upgrades with unified demoMode and server-driven checkout_presentation.")
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

    /// Tracks the active sync task to prevent concurrent evaluations.
    private var syncTask: Task<Void, Never>?

    /// Observes `StoreKitSubscriptionMonitor.stateChanges` so the manager
    /// can transition `.accepted` → `.completed` the moment the user cancels
    /// Apple auto-renew (no ASSN / backend round-trip required).
    private var monitorObservationTask: Task<Void, Never>?

    /// Re-entrancy guard for evaluateEligibility.
    private var isEvaluating = false

    // MARK: - Checkout Preloading

    /// Preloaded checkout URL ready for instant presentation.
    private var preloadedCheckoutURL: URL?

    /// Transaction ID associated with the preloaded checkout.
    private var preloadedTransactionId: String?

    /// In-flight preload task for coalescing concurrent calls.
    private var preloadTask: Task<URL?, Never>?

    /// Convenience alias for Apple subscription status comparison.
    private typealias AppleStatus = StoreKitSubscriptionStatus

    // MARK: - Public Properties

    /// The user identifier for this migration flow.
    public let userId: String

    /// An optional existing Stripe Customer ID (`cus_xxx`) to attach the
    /// migration checkout to.  When provided the backend will use this customer
    /// instead of creating a new one, ensuring a unified Billing Portal view.
    public let stripeCustomerId: String?

    // MARK: - Demo Mode

    /// Previews the tenant-configured migration tip on a device without a sandbox StoreKit purchase.
    ///
    /// When `true`, ``evaluateEligibility()`` uses the tenant's real server-side
    /// ``MigrationPrompt`` — same title, message, CTA, discount, and
    /// `checkout_presentation` the end user would see in production — but bypasses
    /// gates that would otherwise require an active StoreKit subscription first.
    ///
    /// ## Bypassed gates
    ///
    /// - active StoreKit subscription
    /// - rollout bucket hash
    /// - min / max subscription-tenure
    /// - "already has active web subscription"
    ///
    /// ## Still enforced
    ///
    /// - SDK configured via ``ZeroSettle/configure(_:)`` and bootstrapped via ``ZeroSettle/bootstrap(userId:)``
    /// - US jurisdiction (or ``forceUSARegion()``)
    /// - Permanent dismissal
    /// - Server returned a ``RemoteConfig/migration`` payload. If the tenant's
    ///   dashboard has no migration campaign configured, demo mode resolves to
    ///   ``MigrationOffer/State/ineligible`` — there is no hardcoded fallback.
    ///
    /// ## Transactions are disabled in demo mode
    ///
    /// Tapping the tip's CTA while ``demoMode`` is `true` does **not** open
    /// checkout. The SDK sets ``showDemoModeAlert`` and leaves ``state`` at
    /// ``MigrationOffer/State/eligible``; the tip view renders a local alert
    /// explaining the block. No `PaymentIntent` or `SetupIntent` is created on
    /// your Stripe account. To verify the real checkout flow, disable demo mode
    /// and complete a StoreKit sandbox purchase.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #if DEBUG
    /// ZSMigrationManager.demoMode = true
    /// #endif
    ///
    /// ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_test_..."))
    /// try? await ZeroSettle.shared.bootstrap(userId: "test-user")
    /// ```
    ///
    /// - Important: Gate assignments behind a debug build flag (`#if DEBUG`)
    ///   so the property cannot be enabled in a production TestFlight or App
    ///   Store build. The SDK logs a prominent warning the first time the flag
    ///   flips to `true` in a process, but never prevents it.
    /// - SeeAlso: ``forceUSARegion()``, ``resetDismissedState()``,
    ///   ``showDemoModeAlert``, ``ZSOfferManager/demoMode``
    public static var demoMode: Bool = false {
        didSet {
            if demoMode && !oldValue {
                ZSLogger.info(
                    "[MigrationManager] ⚠️ demoMode=true — migration tip will preview " +
                    "real dashboard config without a StoreKit subscription. Checkout " +
                    "CTA is disabled to prevent real charges. Never ship with demoMode on.",
                    category: ZSLogger.Category.migration
                )
            }
        }
    }

    /// `true` when the user tapped the CTA while ``demoMode`` was on.
    ///
    /// Bound to a SwiftUI `.alert(isPresented:)` modifier by ``MigrationTipView``.
    /// SwiftUI flips it back to `false` on OK-dismiss; you typically don't read
    /// or write this directly. Part of the demo-mode plumbing.
    @Published public private(set) var showDemoModeAlert: Bool = false

    // MARK: - Region Override

    /// Forces the jurisdiction check to return `.us`, bypassing the real device locale/storefront.
    ///
    /// Useful for debugging the migration flow from non-US regions.
    /// Call ``forceUSARegion()`` to enable or set directly:
    /// ```swift
    /// ZSMigrationManager.isUSARegionForced = true
    /// ```
    public static var isUSARegionForced: Bool = false

    /// Enables the US region override so the migration tip appears regardless of the device's actual region.
    ///
    /// ```swift
    /// ZSMigrationManager.forceUSARegion()
    /// ```
    public static func forceUSARegion() {
        ZSLogger.info("[MigrationManager] forceUSARegion() called — jurisdiction check will always pass as .us", category: .migration)
        isUSARegionForced = true
    }

    /// Disables the US region override, restoring normal jurisdiction detection.
    public static func resetRegionOverride() {
        ZSLogger.info("[MigrationManager] resetRegionOverride() called — restoring real jurisdiction detection", category: .migration)
        isUSARegionForced = false
    }

    // MARK: - Persistence

    private static let dismissedKeyPrefix = "com.zerosettle.migrateTipDismissed"

    /// Whether the migration tip has been permanently dismissed (persisted across app launches).
    /// - Note: This checks the global (non-user-scoped) key. Prefer ``isPermanentlyDismissed(forUserId:)`` for per-user state.
    public static var isPermanentlyDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKeyPrefix) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKeyPrefix) }
    }

    /// Whether the migration tip has been permanently dismissed for a specific user.
    public static func isPermanentlyDismissed(forUserId userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "\(dismissedKeyPrefix).\(userId)")
    }

    /// Set the dismissed state for a specific user.
    public static func setDismissed(_ dismissed: Bool, forUserId userId: String) {
        UserDefaults.standard.set(dismissed, forKey: "\(dismissedKeyPrefix).\(userId)")
    }

    /// Resets the dismissed state, allowing the migration offer to be shown again.
    public static func resetDismissedState() {
        isPermanentlyDismissed = false
        // Also clear per-user dismissed keys (prefix + ".userId")
        let defaults = UserDefaults.standard
        var clearedCount = 0
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(dismissedKeyPrefix + ".") {
            defaults.removeObject(forKey: key)
            clearedCount += 1
        }
        ZSLogger.info("[MigrationManager] resetDismissedState() — cleared global key + \(clearedCount) per-user key(s)", category: .migration)
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

        // Evaluate immediately and start observing ZeroSettle.shared for changes
        startObserving()
        startMonitoringSubscriptionChanges()
    }

    deinit {
        monitorObservationTask?.cancel()
    }

    /// Subscribe to local StoreKit subscription state changes so the migration
    /// flow flips to `.completed` the moment the user cancels Apple auto-renew
    /// in App Store Settings — independent of ASSN / backend reconciliation.
    private func startMonitoringSubscriptionChanges() {
        monitorObservationTask?.cancel()
        let monitor = ZeroSettle.shared.subscriptionMonitor
        monitorObservationTask = Task { [weak self] in
            for await info in monitor.stateChanges {
                guard !Task.isCancelled else { break }
                await self?.handleSubscriptionInfoChange(info)
            }
        }
    }

    private func handleSubscriptionInfoChange(_ info: StoreKitSubscriptionMonitor.SubscriptionInfo) async {
        guard state == .accepted, storekitCancelRequired else { return }

        // Match against the StoreKit product the user accepted the migration for.
        guard let watchedProductId = offerData?.activeStoreKitProductId else { return }
        guard info.productId == watchedProductId else { return }

        let cancelled = !info.willAutoRenew
            || info.renewalState == .expired
            || info.renewalState == .revoked
        guard cancelled else { return }

        ZSLogger.info(
            "[MigrationManager] Local StoreKit monitor detected cancellation for \(info.productId) (willAutoRenew=\(info.willAutoRenew), state=\(info.renewalState.rawValue)) — transitioning to .completed",
            category: .migration
        )

        storekitCancelRequired = false
        state = .completed
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
                self.startObserving()
            }
        }
    }

    // MARK: - Eligibility

    /// Re-evaluates eligibility as a sequential checklist.
    /// Each check either returns early (not eligible) or falls through to the next.
    /// Mid-flow states (.presented, .accepted, .completed, .dismissed) are locked.
    private func evaluateEligibility() {
        guard !isEvaluating else { return }
        isEvaluating = true

        // Nudge the StoreKit monitor to re-pull renewal state. Transaction.updates
        // does not fire on pure `willAutoRenew` toggles, so a cancel the user made
        // via App Store Settings while the app was foregrounded goes undetected
        // until the next real transaction event. Firing a refresh whenever we
        // recompute offer state means the `.accepted → .completed` transition
        // happens the moment the user interacts with this view.
        Task { [weak self] in
            guard self != nil else { return }
            await ZeroSettle.shared.subscriptionMonitor.refreshIfStale()
        }

        // Demo mode: force out of dismissed state so re-evaluation can proceed
        if Self.demoMode && state == .dismissed {
            state = .loading
        }

        let previousState = state
        defer {
            // Clear preloaded checkout when transitioning away from .eligible.
            // Must happen before resetting isEvaluating to prevent re-entrant evaluation.
            if previousState == .eligible && state != .eligible {
                clearPreloadedCheckout()
            }
            isEvaluating = false
        }
        let iap = ZeroSettle.shared

        // ── Always sync Apple subscription status to backend ──
        let syncEntitlement = iap.entitlements.first(where: { $0.source == .storeKit })
            ?? iap.entitlements.first(where: { $0.source == .webCheckout })
        let syncProductId = syncEntitlement?.productId
        let syncOrigTxnId = syncEntitlement?.storekitOriginalTransactionId
        if let syncProductId {
            syncTask?.cancel()
            syncTask = Task { [weak self] in
                guard let self else { return }
                // Try server-side first (real-time), fall back to on-device StoreKit
                var result = await self.fetchAppleSubscriptionStatusFromServer(originalTransactionId: syncOrigTxnId)
                if result == nil {
                    result = await self.fetchAppleSubscriptionStatus(productId: syncProductId)
                }
                let appleStatus = result?.status ?? AppleStatus.subscribed.rawValue
                let expirationDate = result?.expirationDate
                await self.syncStorekitStatusToBackend(productId: syncProductId, status: appleStatus, expirationDate: expirationDate)

                // If Apple is cancelled and we're in .accepted, transition to .completed
                if appleStatus == AppleStatus.expired.rawValue && self.state == .accepted {
                    self.storekitCancelRequired = false
                    self.state = .completed
                }
            }
        }

        // ── Check 1: Mid-flow lock ──
        guard state == .loading || state == .ineligible || state == .eligible else {
            return
        }

        // ── Check 2: SDK bootstrapped ──
        guard iap.isBootstrapped else {
            state = .loading
            offerData = nil
            return
        }

        // ── Check 3: US-only ──
        let jurisdiction = Self.isUSARegionForced ? .us : (iap.detectedJurisdiction ?? .row)
        guard jurisdiction == .us else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: jurisdiction=\(jurisdiction.rawValue), migration is US-only", category: .migration)
            return
        }
        if Self.isUSARegionForced {
            ZSLogger.info("[MigrationTip] Jurisdiction: .us (forced via forceUSARegion()) — eligible region", category: .migration)
        } else {
            ZSLogger.info("[MigrationTip] Jurisdiction: \(jurisdiction.rawValue) — eligible region", category: .migration)
        }

        // ── Check 4: Demo mode (bypasses all real checks) ──
        if Self.demoMode {
            let demoProductId = iap.products.first?.id ?? "com.example.subscription"
            let prompt = MigrationPrompt(
                productId: demoProductId,
                discountPercent: 15,
                title: "Switch & Save",
                message: "Switch to direct billing and get 15% off forever. Same features, fewer platform fees, and we pass the savings onto you.",
                ctaText: "Save 15% Forever"
            )
            state = .eligible
            offerData = MigrationOffer.OfferData(
                prompt: prompt,
                freeTrialDays: 7,
                activeStoreKitProductId: demoProductId,
                storekitSubscriptionEnd: Date().addingTimeInterval(7 * 86400),
                activeStoreKitOriginalTransactionId: nil
            )
            return
        }

        // ── Check 5: Not permanently dismissed (per-user, with global fallback) ──
        guard !Self.isPermanentlyDismissed(forUserId: userId) && !Self.isPermanentlyDismissed else {
            state = .dismissed
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: permanently dismissed by user", category: .migration)
            return
        }

        // ── Gather entitlements ──
        let subscriptionProductIds = Set(iap.products.filter {
            $0.type == .autoRenewableSubscription || $0.type == .nonRenewingSubscription
        }.map { $0.id })
        let storeKitEntitlements = iap.entitlements.filter { $0.source == .storeKit }
        let activeStoreKitEntitlements = storeKitEntitlements.filter { $0.isActive }
        let webEntitlements = iap.entitlements.filter { $0.source == .webCheckout }
        // Only consider web *subscriptions* — consumable purchases (streak savers, etc.) are irrelevant for migration
        let activeWebSubscriptions = webEntitlements.filter { $0.isActive && subscriptionProductIds.contains($0.productId) }

        // ── Check 6: Has active StoreKit subscription ──
        guard !activeStoreKitEntitlements.isEmpty else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: no active StoreKit subscription", category: .migration)
            return
        }

        // ── Check 7: Both StoreKit + web subscription active ──
        if !activeWebSubscriptions.isEmpty && !activeStoreKitEntitlements.isEmpty {
            let appleWillRenew = activeStoreKitEntitlements.first?.willRenew ?? true
            if appleWillRenew {
                // Apple still renewing → prompt user to cancel
                storekitCancelRequired = true
                state = .accepted
            } else {
                // Apple already cancelled → migration complete
                storekitCancelRequired = false
                state = .completed
            }
            return
        }
        let catalogProducts = iap.products

        // ── Check 8: Web subscription check (uses activeWebSubscriptions from above) ──
        guard activeWebSubscriptions.isEmpty else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: already has active web subscription", category: .migration)
            return
        }

        // ── Check 9: Migration prompt resolved from backend or sandbox ──
        guard let resolved = resolveMigrationPrompt(activeStoreKitEntitlements: activeStoreKitEntitlements) else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: no migration prompt from backend or sandbox", category: .migration)
            return
        }

        let prompt = resolved.prompt
        let matchedEntitlement = resolved.matchedEntitlement

        // ── Check 9.5: Rollout ──
        let rolloutPercent = prompt.rolloutPercent ?? 0
        let digest = SHA256.hash(data: Data(userId.utf8))
        var bucket = 0
        for byte in digest {
            bucket = (bucket &* 256 &+ Int(byte)) % 100
        }
        guard bucket < rolloutPercent else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: user not in rollout cohort (bucket=\(bucket), rollout=\(rolloutPercent)%)", category: .migration)
            return
        }

        // ── Check 10: Target product exists in catalog ──
        guard let targetProduct = catalogProducts.first(where: { $0.id == prompt.productId }) else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[MigrationTip] SKIP: target product \(prompt.productId) not found in catalog", category: .migration)
            return
        }

        // ── Check 11: Subscription tenure from StoreKit ──
        let productId = matchedEntitlement.productId
        Task { [weak self] in
            guard let self else { return }
            let tenureDays = await self.calculateStoreKitTenure(for: productId)

            if tenureDays < prompt.minSubscriptionDays {
                self.state = .ineligible
                self.offerData = nil
                ZSLogger.info("[MigrationTip] SKIP: tenure \(tenureDays)d < min \(prompt.minSubscriptionDays)d", category: .migration)
                return
            }
            if let maxDays = prompt.maxSubscriptionDays, tenureDays > maxDays {
                self.state = .ineligible
                self.offerData = nil
                ZSLogger.info("[MigrationTip] SKIP: tenure \(tenureDays)d > max \(maxDays)d", category: .migration)
                return
            }

            self.applyEligible(prompt: prompt, matchedEntitlement: matchedEntitlement, targetProduct: targetProduct)
        }
    }

    /// Sets state to `.eligible` with the resolved offer data.
    private func applyEligible(prompt: MigrationPrompt, matchedEntitlement: Entitlement, targetProduct: ZSProduct) {
        let iap = ZeroSettle.shared
        let data = MigrationOffer.OfferData(
            prompt: prompt,
            freeTrialDays: prompt.freeTrialDays,
            activeStoreKitProductId: matchedEntitlement.productId,
            storekitSubscriptionEnd: matchedEntitlement.expiresAt,
            activeStoreKitOriginalTransactionId: matchedEntitlement.storekitOriginalTransactionId
        )
        state = .eligible
        offerData = data
    }

    /// Resolves the migration prompt from backend config or synthesizes one in sandbox mode.
    /// Matches the user's active StoreKit entitlements against the prompt's eligible product IDs.
    /// - Returns: A tuple of the resolved prompt (with `productId` set to the matched product)
    ///   and the matched entitlement, or `nil` if no match is found.
    private func resolveMigrationPrompt(activeStoreKitEntitlements: [Entitlement]) -> (prompt: MigrationPrompt, matchedEntitlement: Entitlement)? {
        let iap = ZeroSettle.shared

        // Use backend-provided prompt if available
        if let backendPrompt = iap.remoteConfig?.migration {
            // Find the first active StoreKit entitlement whose productId is in the eligible list
            guard let matchedEntitlement = activeStoreKitEntitlements.first(where: { backendPrompt.eligibleProductIds.contains($0.productId) }) else {
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
                    minSubscriptionDays: backendPrompt.minSubscriptionDays,
                    maxSubscriptionDays: backendPrompt.maxSubscriptionDays,
                    freeTrialDays: backendPrompt.freeTrialDays,
                    title: perProduct.title,
                    message: perProduct.message,
                    ctaText: perProduct.ctaText,
                    rolloutPercent: backendPrompt.rolloutPercent,
                    perProductPrompts: backendPrompt.perProductPrompts
                )
            } else {
                resolvedPrompt = MigrationPrompt(
                    productId: matchedEntitlement.productId,
                    eligibleProductIds: backendPrompt.eligibleProductIds,
                    discountPercent: backendPrompt.discountPercent,
                    minSubscriptionDays: backendPrompt.minSubscriptionDays,
                    maxSubscriptionDays: backendPrompt.maxSubscriptionDays,
                    freeTrialDays: backendPrompt.freeTrialDays,
                    title: backendPrompt.title,
                    message: backendPrompt.message,
                    ctaText: backendPrompt.ctaText,
                    rolloutPercent: backendPrompt.rolloutPercent,
                    perProductPrompts: backendPrompt.perProductPrompts
                )
            }
            return (resolvedPrompt, matchedEntitlement)
        }

        // In sandbox mode, synthesize a prompt so developers can always test the flow
        if iap.isSandbox {
            guard let firstEntitlement = activeStoreKitEntitlements.first else { return nil }
            let prompt = MigrationPrompt(
                productId: firstEntitlement.productId,
                discountPercent: 15,
                title: "Switch & Save",
                message: "Switch to direct billing and get 15% off forever. Same features, fewer platform fees.",
                ctaText: "Save 15% Forever"
            )
            return (prompt, firstEntitlement)
        }

        return nil
    }

    // MARK: - State Transitions

    /// Transition from `.eligible` to `.presented`.
    ///
    /// Call this when you show the migration offer UI or begin the checkout flow.
    public func present() {
        guard state == .eligible else { return }
        state = .presented
    }

    /// Create a payment intent and return the checkout URL.
    ///
    /// Transitions to `.presented` if not already there.
    /// Returns `nil` if checkout creation fails (check ``checkoutError``).
    ///
    /// - Parameter stripeCustomerId: Optional Stripe customer ID to use for this checkout.
    ///   Overrides the value stored on the singleton, which may be `nil` if the manager
    ///   was cached before a customer ID was available (e.g. during `bootstrap()`).
    ///   Falls back to `self.stripeCustomerId` when `nil`.
    /// - Returns: The checkout URL to load in a webview, or `nil` on failure
    @discardableResult
    public func startCheckout(stripeCustomerId: String? = nil) async -> URL? {
        guard let offerData else {
            ZSLogger.error("[MigrationManager] startCheckout() failed — no offerData available", category: .migration)
            checkoutError = ZeroSettleError.notConfigured
            return nil
        }

        // Fast path: consume preloaded checkout URL
        if let url = consumePreloadedURL() {
            return url
        }

        // Wait for in-flight preload if running
        if preloadTask != nil {
            _ = await preloadTask?.value
            if let url = consumePreloadedURL() {
                return url
            }
        }

        // Slow path: create PI on-demand
        if state == .eligible {
            state = .presented
        }

        checkoutError = nil
        isLoading = true

        do {
            let result = try await createCheckout(stripeCustomerId: stripeCustomerId)
            isLoading = false
            checkoutTransactionId = result.transactionId
            return result.url
        } catch {
            checkoutError = error
            isLoading = false
            ZSLogger.error("[MigrationManager] Checkout initiation failed: \(error)", category: .migration)

            // If the product doesn't exist on the backend, the migration offer is invalid —
            // hide the view by transitioning to .ineligible.
            if case .apiError(let detail) = error as? ZeroSettleError, detail.statusCode == 404 {
                state = .ineligible
                self.offerData = nil
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
        guard state == .presented else { return }
        state = .accepted

        // Verify transaction and refresh entitlements (matches ZSPaymentSheet pattern)
        if let transactionId {
            do {
                let backend = try makeBackend()
                let transaction = try await backend.verifyTransaction(transactionId: transactionId)
                await ZeroSettle.shared.delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                await ZeroSettle.shared.refreshEntitlementsAfterCheckout(transaction: transaction)
            } catch {
                ZSLogger.error("[MigrationManager] Transaction verification failed: \(error)", category: .migration)
            }
        }

        // Fire-and-forget conversion tracking
        Task {
            do {
                try await ZeroSettle.shared.trackMigrationConversion(userId: userId)
            } catch {
                ZSLogger.error("[MigrationManager] Conversion tracking failed: \(error)", category: .migration)
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
        guard state == .accepted else { return }

        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                ZSLogger.error("[MigrationManager] No UIWindowScene available", category: .migration)
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
        let appleStatus = result?.status ?? AppleStatus.subscribed.rawValue
        let expirationDate = result?.expirationDate

        if appleStatus == AppleStatus.expired.rawValue {
            storekitCancelRequired = false
            state = .completed
        } else {
            storekitCancelRequired = true
        }

        // Sync status to backend
        if let txnId {
            do {
                let backend = try makeBackend()
                try await backend.updateStorekitStatus(transactionId: txnId, storekitStatus: appleStatus, storekitSubscriptionEnd: expirationDate)
            } catch {
                ZSLogger.error("[MigrationManager] Failed to update backend storekit_status: \(error)", category: .migration)
            }
        }
    }

    /// Query the server for real-time Apple subscription status (bypasses on-device StoreKit cache).
    /// Returns the same tuple as fetchAppleSubscriptionStatus, or nil on failure.
    private func fetchAppleSubscriptionStatusFromServer(originalTransactionId: String?) async -> (status: Int, expirationDate: Date?)? {
        guard let originalTransactionId else { return nil }

        do {
            let backend = try makeBackend()
            let response = try await backend.getStoreKitSubscriptionStatus(originalTransactionId: originalTransactionId)
            return (response.status, response.expiresAt)
        } catch {
            return nil
        }
    }

    /// Query StoreKit for the Apple subscription status.
    /// Returns a tuple of (status, expirationDate) where status is 1 (active) or 2 (cancelled), or nil if unknown.
    /// Active = subscribed + willAutoRenew. Everything else = cancelled.
    private func fetchAppleSubscriptionStatus(productId: String?) async -> (status: Int, expirationDate: Date?)? {
        guard let productId else { return nil }

        guard let product = try? await Product.products(for: [productId]).first,
              let subscription = product.subscription else { return nil }

        guard let statuses = try? await subscription.status,
              let status = statuses.first else { return nil }

        var willAutoRenew = false
        if case .verified(let renewalInfo) = status.renewalInfo {
            willAutoRenew = renewalInfo.willAutoRenew
        }

        var expirationDate: Date? = nil
        if case .verified(let transaction) = status.transaction {
            expirationDate = transaction.expirationDate
        }

        let isActive = status.state == .subscribed && willAutoRenew
        return (isActive ? AppleStatus.subscribed.rawValue : AppleStatus.expired.rawValue, expirationDate)
    }

    /// Syncs the StoreKit subscription status to the backend.
    /// Fetches transaction history by userId, finds the matching web checkout transaction
    /// for the given product, and updates its storekit_status.
    private func syncStorekitStatusToBackend(productId: String?, status: Int, expirationDate: Date? = nil) async {
        do {
            let backend = try makeBackend()
            let transactions = try await backend.getTransactionHistory(userId: userId)

            let matchingTxn = transactions.first { txn in
                txn.source == .webCheckout && txn.status == .completed && (productId == nil || txn.productId == productId)
            }

            if let txn = matchingTxn {
                try await backend.updateStorekitStatus(transactionId: txn.id, storekitStatus: status, storekitSubscriptionEnd: expirationDate)
                checkoutTransactionId = txn.id
            }
        } catch {
            ZSLogger.error("[MigrationManager] Failed to sync Apple status to backend: \(error)", category: .migration)
        }
    }

    /// Dismiss the migration offer.
    ///
    /// Sets the state to `.dismissed` and persists the dismissal in UserDefaults.
    /// Can be called from any state.
    public func dismiss() {
        clearPreloadedCheckout()
        state = .dismissed
        offerData = nil
        Self.setDismissed(true, forUserId: userId)
    }

    // MARK: - Checkout Preloading

    /// Pre-creates a PaymentIntent so the checkout URL is ready before the user taps the CTA.
    ///
    /// Returns the cached URL on subsequent calls. Concurrent calls are coalesced into a single
    /// network request. Does **not** set `isLoading` or transition state.
    ///
    /// - Parameter stripeCustomerId: Optional Stripe customer ID override.
    /// - Returns: The checkout URL, or `nil` if preloading fails or the manager isn't eligible.
    internal func preloadCheckout(stripeCustomerId: String? = nil) async -> URL? {
        guard offerData != nil, state == .eligible else { return nil }

        // Cache hit
        if let preloadedCheckoutURL { return preloadedCheckoutURL }

        // Coalesce concurrent calls
        if let preloadTask {
            return await preloadTask.value
        }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }

            do {
                let result = try await self.createCheckout(stripeCustomerId: stripeCustomerId)
                self.preloadedCheckoutURL = result.url
                self.preloadedTransactionId = result.transactionId
                return result.url
            } catch {
                ZSLogger.error("[MigrationManager] Preload checkout failed: \(error)", category: .migration)
                return nil
            }
        }
        preloadTask = task
        return await task.value
    }

    /// Consumes the preloaded checkout URL if available, transitioning to `.presented`.
    ///
    /// Returns the URL and clears preloaded state. Returns `nil` if nothing was preloaded.
    internal func consumePreloadedURL() -> URL? {
        guard let url = preloadedCheckoutURL else { return nil }

        if state == .eligible {
            state = .presented
        }
        checkoutTransactionId = preloadedTransactionId

        // Clear preloaded state after consumption
        preloadedCheckoutURL = nil
        preloadedTransactionId = nil
        preloadTask = nil

        return url
    }

    /// Cancels any in-flight preload and clears cached checkout state.
    private func clearPreloadedCheckout() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedCheckoutURL = nil
        preloadedTransactionId = nil
    }

    /// Creates a PaymentIntent and sets the default Apple subscription status.
    ///
    /// Shared by `startCheckout()` and `preloadCheckout()` to avoid duplicating
    /// the `initiateCheckout` + `updateStorekitStatus` call sequence.
    private func createCheckout(stripeCustomerId: String?) async throws -> (url: URL?, transactionId: String) {
        guard let offerData else { throw ZeroSettleError.notConfigured }

        let productId = offerData.prompt.productId
        let publishableKey = ZeroSettle.shared.currentConfig?.publishableKey ?? ""
        let resolvedCustomerId = stripeCustomerId ?? self.stripeCustomerId
        let baseURL = ZeroSettle.shared.effectiveBaseURL

        // Use the shared cache to coalesce with the batch preload. If warmUpAll()
        // already created a PI for this product, we get an instant cache hit.
        // If a batch request is in-flight, we join it instead of racing.
        let checkout = await CheckoutResponseCache.shared.fetchOrJoin(
            productId: productId,
            userId: userId,
            publishableKey: publishableKey
        ) { [userId, offerData] in
            guard let baseURL else { return nil }
            let backend = Backend(baseURL: baseURL, publishableKey: publishableKey)
            return try? await backend.initiateCheckout(
                productId: productId,
                userId: userId,
                stripeCustomerId: resolvedCustomerId,
                storekitSubscriptionEnd: offerData.storekitSubscriptionEnd,
                storekitOriginalTransactionId: offerData.activeStoreKitOriginalTransactionId
            )
        }

        guard let checkout else {
            throw ZeroSettleError.checkoutFailed(reason: .other("PI creation failed"))
        }

        // Default Apple subscription to active — "guilty until proven innocent".
        // Updated with real status after manage subscription sheet dismisses.
        do {
            let backend = try makeBackend()
            try await backend.updateStorekitStatus(transactionId: checkout.transactionId, storekitStatus: 1)
        } catch {
            ZSLogger.error("[MigrationManager] Failed to set default storekit_status: \(error)", category: .migration)
        }

        return (URL(string: checkout.checkoutUrl), checkout.transactionId)
    }

    // MARK: - StoreKit Tenure

    /// Calculates the user's subscription tenure in days for a product by finding
    /// the earliest `originalPurchaseDate` across all verified StoreKit transactions.
    private func calculateStoreKitTenure(for productId: String) async -> Int {
        var earliest: Date?
        for await result in SKTransaction.all {
            guard case .verified(let transaction) = result,
                  transaction.productID == productId else { continue }
            let date = transaction.originalPurchaseDate
            if earliest == nil || date < earliest! {
                earliest = date
            }
        }
        guard let earliest else { return 0 }
        return Calendar.current.dateComponents([.day], from: earliest, to: Date()).day ?? 0
    }

    // MARK: - Backend Helper

    private func makeBackend() throws -> Backend {
        try ZeroSettle.shared.makeBackend()
    }

    #if DEBUG
    /// Test-only: force the manager into a given state. Never call from app code.
    /// Needed because ``state`` is `private(set)` and tests for ``present()``
    /// need to seed `.eligible` without running the full eligibility pipeline.
    internal func _setStateForTesting(_ newState: MigrationOffer.State) {
        state = newState
    }
    #endif
}
