import Foundation
import StoreKit
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Unified offer manager for both migration and upgrade flows.
///
/// Unlike `ZSMigrationManager` which requires a StoreKit subscription,
/// `ZSOfferManager` supports all offer types:
/// - **Migration** (StoreKit → web): Same product, switch billing
/// - **Upgrade (storekit_to_web)**: Higher-tier product via web checkout
/// - **Upgrade (web_to_web)**: Higher-tier product via Stripe modify (no WebView)
///
/// The server resolves which offer to show via the `offer` field in the products
/// response. The SDK validates rollout cohort and renders the appropriate UI.
///
/// ## State Machine
///
/// ```
/// loading ──▶ evaluateEligibility() ──▶ ineligible
///                                   └──▶ eligible
///                                         │
///                                    present()
///                                         │
///                                         ▼
///                                      presented
///                                         │
///                              markCheckoutSucceeded()
///                                    ┌────┴────┐
///                                    ▼         ▼
///                               accepted   completed
///                                    │
///                   showAppleSubscriptionManagement()
///                                    │
///                                    ▼
///                               completed
///
///  Any state ──▶ dismiss() ──▶ dismissed (permanent, persisted)
/// ```
///
/// Re-evaluation via `startObserving()` only fires in `.loading`, `.ineligible`,
/// and `.eligible` states — never during an active checkout flow.

/// Identifies which call site triggered a checkout-bookkeeping transition,
/// so analytics / logs can distinguish auto-bookkeeping (the new 1.4.0 path)
/// from the deprecated public methods.
internal enum CheckoutBookkeepingSource: Sendable, CustomStringConvertible {
    /// Triggered automatically by CheckoutSheet.present / .checkoutSheet / purchase().
    case auto
    /// Triggered by deprecated public methods (present(), markCheckoutSucceeded()).
    case manualLegacy

    var description: String {
        switch self {
        case .auto: return "auto"
        case .manualLegacy: return "manualLegacy"
        }
    }
}

@MainActor
public final class ZSOfferManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: Offer.State = .loading
    @Published public private(set) var offerData: Offer.OfferData?
    @Published public private(set) var checkoutError: Error?
    @Published public private(set) var isLoading = false
    @Published public private(set) var storekitCancelRequired = false

    // MARK: - Demo Mode

    /// Previews the tenant-configured offer tip on a device without a real subscription.
    ///
    /// Set to ``ZSDemoMode/migration`` to preview Switch & Save, or
    /// ``ZSDemoMode/upgrade`` to preview Upgrade & Save. The SDK bypasses
    /// client-side eligibility gates AND tells the backend (via
    /// `?demo=migration` / `?demo=upgrade` on the products endpoint) to
    /// surface the corresponding dashboard-configured campaign regardless
    /// of the user's real subscription state.
    ///
    /// ## Bypassed gates (SDK-side)
    ///
    /// - active StoreKit subscription (for `needsAppleCancel` offers)
    /// - min / max subscription-tenure
    /// - "already has active web subscription"
    ///
    /// Note: rollout cohort is gated server-side (no client re-bucketing).
    ///
    /// ## Still enforced
    ///
    /// - SDK configured via ``ZeroSettle/configure(_:)`` and bootstrapped via ``ZeroSettle/bootstrap(userId:)``
    /// - Permanent dismissal
    /// - Server returned ``RemoteConfig/offer`` or ``RemoteConfig/migration``.
    ///   If the tenant's dashboard has no campaign of the requested kind,
    ///   demo mode resolves to ``Offer/State/ineligible`` — no hardcoded fallback.
    ///
    /// ## Transactions are disabled in demo mode
    ///
    /// Tapping the tip's CTA while ``demoMode`` is active does **not** open
    /// checkout. The SDK sets ``showDemoModeAlert`` and leaves ``state`` at
    /// ``Offer/State/eligible``; the tip view renders a local alert explaining
    /// the block. No `PaymentIntent` or `SetupIntent` is created.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #if DEBUG
    /// ZSOfferManager.demoMode = .migration   // preview Switch & Save
    /// // or
    /// ZSOfferManager.demoMode = .upgrade     // preview Upgrade & Save
    /// #endif
    ///
    /// ZeroSettle.shared.configure(.init(publishableKey: "zs_pk_test_..."))
    /// try? await ZeroSettle.shared.bootstrap(userId: "test-user")
    /// ```
    ///
    /// - Important: Gate assignments behind a debug build flag (`#if DEBUG`)
    ///   so the property cannot be activated in a production TestFlight or App
    ///   Store build. The SDK logs a prominent warning the first time the flag
    ///   leaves ``ZSDemoMode/off``, but never prevents it. The backend
    ///   honors the demo signal only on test-mode publishable keys
    ///   (`zs_pk_test_*`) — additional defense in depth.
    /// - SeeAlso: ``showDemoModeAlert``, ``ZSDemoMode``. For the deprecated
    ///   predecessor's equivalent flag, see ``ZSMigrationManager/demoMode``.
    public static var demoMode: ZSDemoMode = .off {
        didSet {
            if demoMode != .off && oldValue == .off {
                ZSLogger.info(
                    "[OfferManager] ⚠️ demoMode=\(demoMode.rawValue) — previewing " +
                    "tenant-configured \(demoMode.rawValue) offer without real " +
                    "subscription. Checkout CTA is disabled to prevent real charges. " +
                    "Never ship with demoMode active.",
                    category: ZSLogger.Category.migration
                )
            }
        }
    }

    /// `true` when the user tapped the CTA while ``demoMode`` was on.
    ///
    /// Read-only from outside the manager. ``OfferTipView`` binds this to a
    /// SwiftUI `.alert(isPresented:)` via a custom `Binding(get:set:)` that
    /// calls ``dismissDemoModeAlert()`` when SwiftUI sets the binding to
    /// `false` on dismiss. You typically don't read or write this directly —
    /// it's part of the demo-mode plumbing.
    @Published public private(set) var showDemoModeAlert: Bool = false

    /// Dismisses the demo-mode alert.
    ///
    /// Called by ``OfferTipView``'s SwiftUI `.alert` binding when the user
    /// taps OK. Safe to call at any time; a no-op if the alert isn't
    /// currently showing. You typically don't call this directly.
    public func dismissDemoModeAlert() {
        showDemoModeAlert = false
    }

    // MARK: - Public Properties

    /// The user ID this manager is currently tracking. Updated in place when
    /// ``ZeroSettle/identify(_:)`` runs, so a manager constructed pre-identify
    /// (via ``ZeroSettle/offerManager(stripeCustomerId:)``) becomes live as soon
    /// as identification completes — without consumers having to re-fetch.
    public private(set) var userId: String

    /// The resolved flow type (nil until eligible).
    public var flowType: Offer.FlowType? { offerData?.flowType }

    /// Whether the current offer requires Apple subscription cancellation.
    public var needsAppleCancel: Bool { offerData?.needsAppleCancel ?? false }

    /// The display copy from the server (nil until offer resolved).
    public var display: Offer.Display? { offerData?.display }

    // MARK: - Private State

    private var stripeCustomerId: String?
    /// Last transaction id captured by `_applyCheckoutCompletion` /
    /// `markCheckoutSucceeded`. `internal` (not `private`) so unit tests can
    /// observe the bookkeeping side-effect; production callers still go
    /// through the public state-machine methods.
    internal var checkoutTransactionId: String?
    private var preloadTask: Task<URL?, Never>?
    private var monitorObservationTask: Task<Void, Never>?
    private var checkoutPollTask: Task<Void, Never>?
    private let impressionDedupe = ImpressionDedupe()

    // Persistence keys
    private static let dismissedKeyPrefix = "com.zerosettle.offerTipDismissed"

    /// Active StoreKit entitlements for the current user.
    /// Used to check migration eligibility and find subscription details.
    private var activeStoreKitEntitlements: [Entitlement] {
        ZeroSettle.shared.entitlements.filter { $0.source == .storeKit && $0.isActive }
    }

    // MARK: - Init

    @available(*, deprecated, message: "Call ZeroSettle.shared.identify(_:) once at app launch, then use ZeroSettle.shared.offerManager(stripeCustomerId:) instead. Direct init bypasses the SDK's identity tracking. Will be removed in ZeroSettleKit 2.0.")
    public init(userId: String, stripeCustomerId: String? = nil) {
        self.userId = userId
        self.stripeCustomerId = stripeCustomerId
        startObserving()
        startMonitoringSubscriptionChanges()
    }

    /// Internal designated init used by SDK-internal fallback paths
    /// (`OfferTipView` constructs a dormant manager when `identify(_:)` hasn't
    /// run). Routes around the public init's deprecation warning so internal
    /// build logs stay clean. External callers should use the factory
    /// ``ZeroSettle/offerManager(stripeCustomerId:)``.
    internal init(activeUserId userId: String, stripeCustomerId: String? = nil) {
        self.userId = userId
        self.stripeCustomerId = stripeCustomerId
        startObserving()
        startMonitoringSubscriptionChanges()
    }

    deinit {
        monitorObservationTask?.cancel()
    }

    // MARK: - Identity Promotion

    /// Updates the manager's tracked user. Called by ``ZeroSettle/identify(_:)``
    /// so a manager that was eagerly created pre-identify (e.g., to back an
    /// `OfferTipView` constructed before login) becomes live without forcing
    /// consumers to re-fetch the manager. No-op when the userId is unchanged.
    ///
    /// Side effects: re-evaluates eligibility (which may transition state out
    /// of `.loading`/`.ineligible`).
    internal func setActiveUserId(_ newId: String) {
        guard newId != userId else { return }
        userId = newId
        // Re-run eligibility against the new identity. `evaluateEligibility`
        // is idempotent and gates on terminal states internally.
        evaluateEligibility()
    }

    // MARK: - Subscription Monitor Integration

    /// Subscribe to local StoreKit subscription state changes so the offer
    /// flow can flip to `.completed` the moment the user cancels Apple
    /// auto-renew in App Store Settings — no ASSN / backend round-trip needed.
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

    /// Consumes a `StoreKitSubscriptionMonitor.SubscriptionInfo` update and
    /// transitions state when appropriate. Only acts while in `.accepted` with
    /// `storekitCancelRequired == true` — outside of that window, the offer
    /// flow has no pending "cancel Apple" expectation to resolve.
    private func handleSubscriptionInfoChange(_ info: StoreKitSubscriptionMonitor.SubscriptionInfo) async {
        ZSLogger.debug(
            "[OfferManager] handleSubscriptionInfoChange: productId=\(info.productId) willAutoRenew=\(info.willAutoRenew) renewalState=\(info.renewalState.rawValue) | state=\(state) storekitCancelRequired=\(storekitCancelRequired)",
            category: .migration
        )
        guard state == .accepted, storekitCancelRequired else { return }
        guard let data = offerData else { return }

        // The product to watch is whichever StoreKit product the user is
        // migrating away from. For migration flows that's the same as the
        // target product (same reference_id); for storekit_to_web upgrades
        // it's the `fromProductId` the user currently holds.
        let watchedProductId = data.fromProductId ?? data.productId
        ZSLogger.debug(
            "[OfferManager] handleSubscriptionInfoChange: watchedProductId=\(watchedProductId) info.productId=\(info.productId) match=\(info.productId == watchedProductId)",
            category: .migration
        )
        guard info.productId == watchedProductId else { return }

        let cancelled = !info.willAutoRenew
            || info.renewalState == .expired
            || info.renewalState == .revoked
        guard cancelled else { return }

        ZSLogger.info(
            "[OfferManager] Local StoreKit monitor detected cancellation for \(info.productId) (willAutoRenew=\(info.willAutoRenew), state=\(info.renewalState.rawValue)) — transitioning to .completed",
            category: .migration
        )

        storekitCancelRequired = false
        state = .completed

        // Fire-and-forget: nudge the backend so the dashboard ledger
        // reflects the local observation. Best-effort — never throws.
        await syncCancellationToBackend(info: info)
    }

    /// Best-effort sync of the cancellation signal to the backend. The next
    /// StoreKit sync will also carry the updated `willAutoRenew` via the
    /// extended payload, but this call updates the transaction row directly
    /// so the dashboard reflects the change immediately.
    private func syncCancellationToBackend(info: StoreKitSubscriptionMonitor.SubscriptionInfo) async {
        guard let txnId = checkoutTransactionId else { return }
        do {
            let backend = try makeBackend()
            // Status 2 = cancelled/expired in the SDK's convention, matches
            // `showAppleSubscriptionManagement()` and StoreKitSubscriptionStatus.
            try await backend.updateStorekitStatus(
                transactionId: txnId,
                storekitStatus: 2,
                storekitSubscriptionEnd: nil
            )
        } catch {
            ZSLogger.error("[OfferManager] Failed to sync local cancellation to backend: \(error)", category: .migration)
        }
    }

    // MARK: - Observation

    private func startObserving() {
        // Re-evaluate eligibility when ZeroSettle.shared properties change
        // (isBootstrapped, remoteConfig, entitlements, products).
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

    private func evaluateEligibility() {
        // Don't re-evaluate mid-flow states
        guard [.loading, .ineligible, .eligible].contains(state) else { return }

        let iap = ZeroSettle.shared
        guard iap.isBootstrapped else { return }

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

        // Check dismissal
        if Self.isPermanentlyDismissed(forUserId: userId) {
            state = .ineligible
            return
        }

        // Web checkout disabled for this jurisdiction — tenant hasn't enabled
        // it for the user's region via JurisdictionCheckoutConfig, or the remote
        // config hasn't loaded yet (isWebCheckoutEnabled defaults to true
        // pre-load, so this only bites once config arrives). The offer tip would
        // fail at checkout time anyway; skip rendering it.
        guard iap.isWebCheckoutEnabled else {
            state = .ineligible
            ZSLogger.info(
                "[OfferManager] SKIP: web checkout disabled for jurisdiction=\(iap.effectiveJurisdiction.rawValue)",
                category: .migration
            )
            return
        }

        // Prefer the unified `offer` field from the server
        if let offer = iap.remoteConfig?.offer {
            resolveFromOffer(offer, iap: iap)
            return
        }

        // Fall back to legacy `migration` field for old servers
        if let migration = iap.remoteConfig?.migration {
            resolveFromMigration(migration, iap: iap)
            return
        }

        state = .ineligible
    }

    private func resolveFromOffer(_ offer: Offer.OfferData, iap: ZeroSettle) {
        // Rollout gate is server-side (api/services/offer_service.py); client-side re-bucketing was removed as redundant + risk of false exclusion.

        // Verify target product exists in catalog
        let targetId = offer.checkoutProductId
        guard iap.products.contains(where: { $0.id == targetId }) else {
            ZSLogger.info("[OfferManager] Target product \(targetId) not found in catalog", category: .migration)
            state = .ineligible
            return
        }

        // Migration and storekit_to_web flows require an active StoreKit subscription
        // (skipped in demo mode — the dev is previewing without a real purchase).
        if !Self.demoMode.isActive, offer.needsAppleCancel {
            guard !activeStoreKitEntitlements.isEmpty else {
                ZSLogger.info("[OfferManager] Skipping: no active StoreKit subscription to migrate", category: .migration)
                state = .ineligible
                return
            }
        }

        // Resolve per-product prompt if applicable
        var resolvedOffer = offer
        if let perProduct = offer.perProductPrompts {
            // Find which eligible product the user currently has
            let userProducts = iap.entitlements.map(\.productId)
            for pid in offer.eligibleProductIds {
                if userProducts.contains(pid), let override = perProduct[pid] {
                    // Use per-product display + product_id
                    resolvedOffer = Offer.OfferData(
                        flowType: offer.flowType,
                        productId: override.productId,
                        eligibleProductIds: offer.eligibleProductIds,
                        savingsPercent: override.savingsPercent,
                        display: override.display,
                        freeTrialDays: offer.freeTrialDays,
                        minSubscriptionDays: offer.minSubscriptionDays,
                        maxSubscriptionDays: offer.maxSubscriptionDays,
                        rolloutPercent: offer.rolloutPercent,
                        upgradeType: offer.upgradeType,
                        fromProductId: pid,
                        toProductId: override.productId,
                        variantId: offer.variantId,
                        perProductPrompts: nil,
                        checkoutPresentation: offer.checkoutPresentation ?? nil
                    )
                    break
                }
            }
        }

        offerData = resolvedOffer
        state = .eligible
        ZSLogger.info("[OfferManager] Eligible: flowType=\(offer.flowType.rawValue) product=\(targetId)", category: .migration)
    }

    private func resolveFromMigration(_ migration: MigrationPrompt, iap: ZeroSettle) {
        // Legacy path: requires StoreKit subscription (same as ZSMigrationManager).
        // Demo mode: synthesize a virtual SK entitlement against the server's
        // migration prompt so the dev can preview without a real sandbox purchase.
        var skEntitlements = activeStoreKitEntitlements
        if Self.demoMode.isActive && skEntitlements.isEmpty {
            if let synthesized = Self.synthesizeDemoEntitlement(from: migration) {
                skEntitlements = [synthesized]
                ZSLogger.info(
                    "[OfferManager] DEMO MODE: synthesized active StoreKit entitlement for productId=\(synthesized.productId)",
                    category: .migration
                )
            }
        }
        guard !skEntitlements.isEmpty else {
            state = .ineligible
            return
        }

        // Find matched product
        guard let matched = skEntitlements.first(where: { migration.eligibleProductIds.contains($0.productId) }) ?? skEntitlements.first else {
            state = .ineligible
            return
        }

        // Build Offer.OfferData from MigrationPrompt
        let perProduct = migration.perProductPrompts?[matched.productId]
        let discount = perProduct?.discountPercent ?? migration.discountPercent

        let display = Offer.Display(
            offerTitle: perProduct?.title ?? migration.title,
            offerMessage: perProduct?.message ?? migration.message,
            offerCta: perProduct?.ctaText ?? migration.ctaText,
            acceptedTitle: "",  // SDK defaults
            acceptedMessage: "",
            acceptedCta: "",
            completedTitle: "",
            completedMessage: ""
        )

        offerData = Offer.OfferData(
            flowType: .migration,
            productId: matched.productId,
            eligibleProductIds: migration.eligibleProductIds,
            savingsPercent: discount,
            display: display,
            freeTrialDays: migration.freeTrialDays,
            minSubscriptionDays: migration.minSubscriptionDays,
            maxSubscriptionDays: migration.maxSubscriptionDays,
            rolloutPercent: migration.rolloutPercent,
            upgradeType: nil,
            fromProductId: nil,
            toProductId: nil,
            variantId: nil,
            perProductPrompts: nil,
            checkoutPresentation: nil
        )
        state = .eligible
    }

    // MARK: - Bookkeeping Internals

    /// Idempotent transition from `.eligible` → `.presented`. Called by both
    /// the auto-bookkeeping helper (Task 4) and the deprecated public
    /// `present()` (Task 3). Any state other than `.eligible` is a no-op so
    /// combined call paths never double-fire.
    internal func _armForCheckout(source: CheckoutBookkeepingSource) {
        guard state == .eligible else {
            if source == .manualLegacy {
                ZSLogger.info(
                    "[OfferManager] _armForCheckout(.manualLegacy) skipped — state already \(state); auto-path likely advanced it",
                    category: .migration
                )
            }
            return
        }
        ZSLogger.info("[OfferManager] _armForCheckout(\(source)) → state .eligible → .presented", category: .migration)
        state = .presented
    }

    /// Idempotent transition out of `.presented` after a successful checkout.
    /// Called by both the auto-bookkeeping helper (Task 4) and the deprecated
    /// public `markCheckoutSucceeded` (Task 3).
    ///
    /// - For offers that require Apple-side cancellation (`needsAppleCancel`):
    ///   `.presented` → `.accepted`, and `storekitCancelRequired` is set.
    /// - Otherwise: `.presented` → `.completed`.
    ///
    /// Conversion analytics fire fire-and-forget for `.migration` and
    /// `.upgrade(.storekitToWeb)` flows. Any state other than `.presented`,
    /// or a missing `offerData`, is a no-op.
    internal func _applyCheckoutCompletion(
        transactionId: String?,
        source: CheckoutBookkeepingSource
    ) async {
        guard state == .presented else {
            if source == .manualLegacy {
                ZSLogger.info(
                    "[OfferManager] _applyCheckoutCompletion(.manualLegacy) skipped — state \(state); auto-path likely already advanced. Drop deprecated markCheckoutSucceeded() — bookkeeping is automatic.",
                    category: .migration
                )
            }
            return
        }
        guard let data = offerData else {
            ZSLogger.error(
                "[OfferManager] _applyCheckoutCompletion(\(source)) reached .presented with nil offerData — defensive no-op",
                category: .migration
            )
            return
        }

        checkoutTransactionId = transactionId
        if data.needsAppleCancel {
            storekitCancelRequired = true
            state = .accepted
        } else {
            state = .completed
        }
        ZSLogger.info(
            "[OfferManager] _applyCheckoutCompletion(\(source)) → state .presented → \(state) txnId=\(transactionId ?? "nil")",
            category: .migration
        )

        // Conversion analytics — fire-and-forget for migration & storekitToWeb flows.
        if data.flowType == .migration || data.upgradeType == .storekitToWeb {
            Task {
                do {
                    ZeroSettle.shared.setActiveUserId(userId)
                    try await ZeroSettle.shared._trackMigrationConversionImpl(userId: userId)
                } catch {
                    ZSLogger.error("[OfferManager] Conversion tracking failed: \(error)", category: .migration)
                }
            }
        }
    }

    // MARK: - Public Methods

    /// Transition from `.eligible` → `.presented`.
    @available(*, deprecated, message: "Bookkeeping is automatic when you call .checkoutSheet(...) / CheckoutSheet.present / ZeroSettle.shared.purchase / Flutter presentPaymentSheet. Will be removed in ZeroSettleKit 2.0.")
    public func present() {
        _present()
    }

    /// Internal entry point for the legacy CTA-tap flow. Same body as the
    /// deprecated public `present()` — preserves the demo-mode guard before
    /// arming the checkout. Extracted so Kit's own UI (e.g. `OfferTipView`)
    /// can drive the legacy CTA path without tripping its own deprecation
    /// warning.
    internal func _present() {
        guard state == .eligible else {
            ZSLogger.info("[OfferManager] present() skipped — state is \(state), expected .eligible", category: .migration)
            return
        }
        if Self.demoMode.isActive {
            showDemoModeAlert = true
            ZSLogger.info(
                "[OfferManager] CTA tap blocked: demoMode=\(Self.demoMode.rawValue) — alert shown, no checkout initiated",
                category: .migration
            )
            return
        }
        _armForCheckout(source: .manualLegacy)
    }

    /// **Advanced — raw URL escape hatch.** For ordinary use, prefer
    /// `ZeroSettle.shared.purchase(productId:)`, `CheckoutSheet.present(...)`,
    /// or the SwiftUI `.checkoutSheet(item:)` modifier. Those entry points
    /// handle the offer state machine automatically — you don't need to
    /// call `present()` or `markCheckoutSucceeded()` yourself.
    ///
    /// Use this method only when you need full control over presentation or
    /// transport: a custom WebView with bespoke chrome, a third-party browser
    /// SDK, or a context where there's no view hierarchy at all (CLI/server).
    ///
    /// When you go down this path, you are responsible for calling
    /// `markCheckoutSucceeded(transactionId:)` after your out-of-band
    /// checkout completes. The auto-bookkeeping path doesn't apply to URLs
    /// you handle yourself.
    ///
    /// - Parameters:
    ///   - stripeCustomerId: Optional Stripe customer ID for unified billing portal.
    ///   - checkoutMode: Pass `.browser` for Safari / SFSafariViewController paths.
    ///     `nil` defers to the backend default (`.native`, the WebView-embed
    ///     template). Mismatching the mode and the presentation renders the
    ///     wrong checkout page.
    /// - Returns: The checkout URL for WebView, or nil for web-to-web upgrades
    ///   (handled internally).
    public func startCheckout(
        stripeCustomerId: String? = nil,
        checkoutMode: CheckoutMode? = nil
    ) async -> URL? {
        // Demo mode: never initiate a real PaymentIntent. The view layer
        // should already have short-circuited; this is defense in depth.
        if Self.demoMode.isActive { return nil }
        guard let data = offerData else { return nil }
        isLoading = true
        checkoutError = nil

        do {
            switch (data.flowType, data.upgradeType) {
            case (.upgrade, .webToWeb):
                try await executeWebToWebUpgrade(data: data)
                isLoading = false
                return nil  // No WebView needed

            default:
                let url = try await startWebViewCheckout(
                    data: data,
                    stripeCustomerId: stripeCustomerId ?? self.stripeCustomerId,
                    checkoutMode: checkoutMode
                )
                isLoading = false
                return url
            }
        } catch {
            checkoutError = error
            isLoading = false
            ZSLogger.error("[OfferManager] Checkout failed: \(error)", category: .migration)
            handleCheckoutFailure(error: error)
            return nil
        }
    }

    /// Move the state machine out of `.presented` after a failed checkout
    /// initiation. Without this transition the OfferTipView's CTA tap loops:
    /// `present()` short-circuits on `state == .presented`, the URL fetch
    /// fails again, ctaTapped resets, the user taps, and we re-fail. The
    /// buyer sees a "spin → reset → spin" UI with no progress.
    ///
    /// * `migration_unavailable` (503) → `.ineligible` and refresh products.
    ///   The backend has authoritative truth on whether this user qualifies
    ///   for the offer (server-side entitlement check). If the SDK got here
    ///   with a stale eligible-evaluation, trust the backend and demote.
    ///   The refresh re-syncs products + remoteConfig from the server so
    ///   the next eligibility evaluation matches the server's view.
    /// * Any other error → `.eligible` so the user can retry once whatever
    ///   transient condition cleared (network blip, server cold start, etc.).
    private func handleCheckoutFailure(error: Error) {
        let detail = (error as? ZeroSettleError).flatMap { e -> APIErrorDetail? in
            if case let .apiError(d) = e { return d }
            return nil
        }
        // Match either the structured `code` field (newer backend) or the
        // human-readable `error` field (older backend, parsed into
        // serverMessage). Keeping both keeps the SDK forward-compatible
        // through the rollout window.
        let isMigrationUnavailable = detail?.serverCode == "migration_unavailable"
            || detail?.serverMessage == "migration_unavailable"

        if isMigrationUnavailable {
            ZSLogger.info(
                "[OfferManager] migration_unavailable — demoting state .presented→.ineligible and refreshing products",
                category: .migration
            )
            state = .ineligible
            Task { [weak self] in
                guard let self else { return }
                _ = try? await ZeroSettle.shared.fetchProducts(userId: self.userId)
            }
        } else if state == .presented {
            ZSLogger.info(
                "[OfferManager] checkout failed (transient) — reverting state .presented→.eligible for retry",
                category: .migration
            )
            state = .eligible
        }
    }

    /// Mark checkout as succeeded. Verifies transaction, refreshes entitlements,
    /// and handles post-checkout state transitions.
    @available(*, deprecated, message: "Bookkeeping is automatic when you call .checkoutSheet(...) / CheckoutSheet.present / ZeroSettle.shared.purchase / Flutter presentPaymentSheet. The body is preserved through 1.x for adopters using `startCheckout` (raw URL escape hatch) who need to call it manually after their out-of-band checkout completes. Will be removed in ZeroSettleKit 2.0.")
    public func markCheckoutSucceeded(transactionId: String? = nil) async {
        ZSLogger.info("[OfferManager] markCheckoutSucceeded called. state=\(state) needsAppleCancel=\(offerData?.needsAppleCancel ?? false)", category: .migration)

        // Preserve legacy guard: if not in `.presented`, this is a no-op for
        // the entire method body — including verify+delegate+refresh. Adopters
        // calling this method when state has already advanced (e.g., the
        // auto-path beat them to it) must NOT see a duplicate verify call or
        // a duplicate delegate fire. `_applyCheckoutCompletion` enforces the
        // same guard for the state-transition half, so this top-level guard
        // is redundant for state but necessary to gate the verify chain.
        guard state == .presented else {
            await _applyCheckoutCompletion(transactionId: transactionId, source: .manualLegacy)
            return
        }

        // Verify transaction + refresh entitlements — preserved from legacy
        // implementation because raw-URL escape-hatch adopters call this method
        // after their out-of-band checkout completes and depend on the
        // verify+delegate+refresh chain. The auto-path (Task 4) skips this
        // chain because CheckoutSheet.present already does both.
        if let transactionId {
            await _verifyAndRefreshAfterCheckout(transactionId: transactionId)
        }

        await _applyCheckoutCompletion(transactionId: transactionId, source: .manualLegacy)
    }

    /// Internal verify+delegate+refresh chain shared by the deprecated
    /// `markCheckoutSucceeded` and the legacy raw-URL polling path
    /// (`startCheckoutCompletionPoll`). Extracted so non-deprecated internal
    /// callers don't have to route through the deprecated public method and
    /// trigger spurious deprecation warnings inside Kit's own sources.
    internal func _verifyAndRefreshAfterCheckout(transactionId: String) async {
        do {
            let backend = try makeBackend()
            let transaction = try await backend.verifyTransaction(transactionId: transactionId)
            await ZeroSettle.shared.delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
            await ZeroSettle.shared.refreshEntitlementsAfterCheckout(transaction: transaction)
        } catch {
            ZSLogger.error("[OfferManager] Transaction verification failed: \(error)", category: .migration)
        }
    }

    /// Abort an in-flight browser checkout — cancels the poll task and
    /// reverts `state` from `.presented` back to `.eligible` so the offer
    /// card's CTA becomes tappable again. Safe to call from user-abort
    /// signals (SafariVC dismissal without paying, app foreground after
    /// the user returned from external Safari without completing).
    ///
    /// If the user later does complete the original checkout in Safari,
    /// the UL callback path refreshes entitlements and `evaluateEligibility`'s
    /// Check 7 (active StoreKit + active web sub) advances state to
    /// `.accepted` — this method only releases the lock, it doesn't
    /// prevent eventual success.
    internal func releasePendingCheckout() {
        guard state == .presented else { return }
        checkoutPollTask?.cancel()
        checkoutPollTask = nil
        state = .eligible
    }

    /// Poll the active checkout transaction until it reaches a terminal state.
    ///
    /// Browser-checkout flows (`.safari` / `.safariVC`) don't get an automatic
    /// state transition from the universal-link callback path —
    /// `processCheckoutCallback` in `ZeroSettle` updates entitlements and fires
    /// the host-app delegate but doesn't call `markCheckoutSucceeded`.
    /// Polling closes that gap so the offer manager advances on its own:
    ///   - `completed` / `processing` → `markCheckoutSucceeded(transactionId:)`,
    ///     transitioning to `.accepted` and dismissing the in-app sheet via
    ///     the view's `onChange(of: state)` observer.
    ///   - `failed` → state reverts to `.eligible`, `checkoutError` is set so
    ///     callers can render a retry affordance, and the sheet dismisses.
    ///
    /// Cancels any prior poll task. Exits early if `state` advances away from
    /// `.presented` (success path completed by another mechanism, or user
    /// abandoned and the manager was reset).
    internal func startCheckoutCompletionPoll() {
        checkoutPollTask?.cancel()
        guard let transactionId = checkoutTransactionId else { return }
        let backend: Backend
        do {
            backend = try makeBackend()
        } catch {
            ZSLogger.error("[OfferManager] Checkout poll could not resolve backend: \(error)", category: .migration)
            return
        }
        checkoutPollTask = Task { @MainActor [weak self] in
            let outcome = await CheckoutTransactionPoller.poll(
                transactionId: transactionId,
                backend: backend,
                shouldContinue: { self?.state == .presented }
            )
            guard let self else { return }
            switch outcome {
            case .completed:
                // Internal poll-completion path — drives the verify chain +
                // state transition directly via canonical internals so this
                // non-deprecated source code doesn't trigger a deprecation
                // warning. Mirrors what the deprecated `markCheckoutSucceeded`
                // does for raw-URL adopters who call it manually.
                if self.state == .presented {
                    await self._verifyAndRefreshAfterCheckout(transactionId: transactionId)
                }
                await self._applyCheckoutCompletion(transactionId: transactionId, source: .manualLegacy)
            case .failed:
                ZSLogger.info("[OfferManager] Checkout poll terminal: failed (txn=\(transactionId))", category: .migration)
                self.state = .eligible
                self.checkoutError = ZeroSettleError.checkoutFailed(reason: .other("Payment failed"))
            case .exhausted:
                ZSLogger.error("[OfferManager] Checkout poll exhausted (txn=\(transactionId))", category: .migration)
            case .terminalError(let error):
                ZSLogger.error("[OfferManager] Checkout poll terminal error (txn=\(transactionId)): \(error.localizedDescription)", category: .migration)
                self.state = .eligible
                self.checkoutError = error
            }
        }
    }

    /// Open the Apple subscription management sheet, then verify cancellation
    /// via server-side Apple API (real-time). Falls back to on-device StoreKit.
    public func showAppleSubscriptionManagement() async {
        guard state == .accepted else {
            ZSLogger.info("[OfferManager] showAppleSubscriptionManagement() skipped — state is \(state), expected .accepted", category: .migration)
            return
        }

        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                ZSLogger.error("[OfferManager] No UIWindowScene available", category: .migration)
                return
            }
            try await AppStore.showManageSubscriptions(in: windowScene)
        } catch {
            ZSLogger.error("[OfferManager] Failed to open subscription management: \(error)", category: .migration)
            return
        }

        // Sheet dismissed — verify cancellation.
        let skEntitlement = activeStoreKitEntitlements.first
        let origTxnId = skEntitlement?.storekitOriginalTransactionId
        let watchedProductId = offerData.map { $0.fromProductId ?? $0.productId }
        let txnId = checkoutTransactionId

        ZSLogger.info(
            "[OfferManager] Sheet dismissed — skEntitlement.productId=\(skEntitlement?.productId ?? "nil") origTxnId=\(origTxnId ?? "nil") watchedProductId=\(watchedProductId ?? "nil") txnId=\(txnId ?? "nil")",
            category: .migration
        )

        // Step 1: Force a local StoreKit refresh.
        // Transaction.updates does NOT fire for willAutoRenew flips. didBecomeActive
        // doesn't fire either — the app stays in the foreground during this in-app sheet.
        // Without an explicit refresh the monitor stays stale and stateChanges never emits.
        let monitor = ZeroSettle.shared.subscriptionMonitor
        let monitorStateBefore = watchedProductId.flatMap { monitor.willAutoRenew(for: $0) }
        ZSLogger.info("[OfferManager] Local monitor BEFORE refresh: watchedProduct willAutoRenew=\(String(describing: monitorStateBefore))", category: .migration)
        ZSLogger.info("[OfferManager] All monitor products before refresh: \(monitor.subscriptionInfoByProductId.map { "\($0.key)=willAutoRenew:\($0.value.willAutoRenew)" }.joined(separator: ", "))", category: .migration)

        await monitor.refreshIfStale()

        let monitorStateAfter = watchedProductId.flatMap { monitor.willAutoRenew(for: $0) }
        ZSLogger.info("[OfferManager] Local monitor AFTER refresh: watchedProduct willAutoRenew=\(String(describing: monitorStateAfter))", category: .migration)
        ZSLogger.info("[OfferManager] All monitor products after refresh: \(monitor.subscriptionInfoByProductId.map { "\($0.key)=willAutoRenew:\($0.value.willAutoRenew)" }.joined(separator: ", "))", category: .migration)

        let cancelledLocally = monitorStateAfter == false

        // Step 2: Server-side check for revoke/expire or as confirmation fallback.
        var appleStatus = 1 // default: still subscribed
        var expirationDate: Date?
        var serverAutoRenewEnabled: Bool?
        if let origTxnId {
            do {
                let backend = try makeBackend()
                let statusResponse = try await backend.getStoreKitSubscriptionStatus(originalTransactionId: origTxnId)
                appleStatus = statusResponse.status
                expirationDate = statusResponse.expiresAt
                serverAutoRenewEnabled = statusResponse.autoRenewEnabled
                ZSLogger.info("[OfferManager] Server status: appleStatus=\(appleStatus) autoRenewEnabled=\(String(describing: serverAutoRenewEnabled)) expiresAt=\(String(describing: expirationDate))", category: .migration)
            } catch {
                ZSLogger.error("[OfferManager] Server-side Apple status check failed: \(error)", category: .migration)
            }
        } else {
            ZSLogger.info("[OfferManager] No origTxnId — skipping server status check", category: .migration)
        }

        let cancelled = cancelledLocally
            || appleStatus == 5 /* revoked */
            || appleStatus == 2 /* expired */
            || serverAutoRenewEnabled == false

        ZSLogger.info(
            "[OfferManager] Cancellation result: cancelledLocally=\(cancelledLocally) appleStatus=\(appleStatus) serverAutoRenewEnabled=\(String(describing: serverAutoRenewEnabled)) → cancelled=\(cancelled)",
            category: .migration
        )

        if cancelled {
            storekitCancelRequired = false
            state = .completed
            ZSLogger.info("[OfferManager] → state=.completed", category: .migration)
        } else {
            storekitCancelRequired = true
            ZSLogger.info("[OfferManager] → still active, storekitCancelRequired=true", category: .migration)
        }

        // Sync status to backend
        if let txnId {
            do {
                let backend = try makeBackend()
                try await backend.updateStorekitStatus(transactionId: txnId, storekitStatus: appleStatus, storekitSubscriptionEnd: expirationDate)
            } catch {
                ZSLogger.error("[OfferManager] Failed to sync storekit_status: \(error)", category: .migration)
            }
        }
    }

    /// Dismiss the offer and persist dismissal.
    public func dismiss() {
        state = .dismissed
        Self.setDismissed(true, forUserId: userId)
    }

    /// Preload checkout session for faster presentation.
    public func preloadCheckout(stripeCustomerId: String? = nil) async -> URL? {
        // Demo mode: never initiate a real PaymentIntent. The tip view's
        // .alert handles the CTA; preload is a no-op in demo mode.
        if Self.demoMode.isActive { return nil }
        guard let data = offerData else { return nil }

        // Web-to-web doesn't need preloading (no WebView)
        if data.upgradeType == .webToWeb { return nil }

        return try? await startWebViewCheckout(
            data: data,
            stripeCustomerId: stripeCustomerId ?? self.stripeCustomerId
        )
    }

    // MARK: - Private Checkout Helpers

    private func startWebViewCheckout(
        data: Offer.OfferData,
        stripeCustomerId: String?,
        checkoutMode: CheckoutMode? = nil
    ) async throws -> URL {
        let backend = try makeBackend()

        // Find StoreKit subscription end for migration trial alignment
        var storekitEnd: Date?
        var storekitOrigTxnId: String?

        if data.needsAppleCancel {
            let skEntitlement = activeStoreKitEntitlements.first
            storekitEnd = skEntitlement?.expiresAt
            storekitOrigTxnId = skEntitlement?.storekitOriginalTransactionId
        }

        let checkout = try await backend.initiateCheckout(
            productId: data.checkoutProductId,
            userId: userId,
            stripeCustomerId: stripeCustomerId,
            storekitSubscriptionEnd: storekitEnd,
            storekitOriginalTransactionId: storekitOrigTxnId,
            checkoutMode: checkoutMode
        )

        checkoutTransactionId = checkout.transactionId
        guard let url = URL(string: checkout.checkoutUrl) else {
            throw ZeroSettleError.apiError(APIErrorDetail(statusCode: nil, serverMessage: "Invalid checkout URL", serverCode: nil, underlyingError: nil))
        }
        return url
    }

    private func executeWebToWebUpgrade(data: Offer.OfferData) async throws {
        guard let fromId = data.fromProductId, let toId = data.toProductId else {
            throw ZeroSettleError.notConfigured
        }

        let backend = try makeBackend()
        let request = UpgradeOffer.ExecuteRequest(
            userId: userId,
            currentProductId: fromId,
            targetProductId: toId
        )
        try await backend.executeUpgradeOffer(request)

        // Transition directly to completed (no Apple cancel needed)
        state = .completed
        ZSLogger.info("[OfferManager] Web-to-web upgrade executed: \(fromId) → \(toId)", category: .migration)
    }

    private func makeBackend() throws -> Backend {
        try ZeroSettle.shared.makeBackend()
    }

    // MARK: - Impression Reporting

    /// Report a real on-screen impression of the offer banner — once per
    /// (session, variant). Safe to call repeatedly (e.g. on every scroll frame);
    /// the dedupe gate makes all but the first call a no-op.
    func reportImpressionIfNeeded() {
        guard let data = offerData else { return }
        let session = ZeroSettle.shared.sessionId
        let uid = userId.isEmpty ? "anonymous" : userId
        let key = "\(uid):\(session):\(data.variantId ?? -1)"
        guard impressionDedupe.shouldReport(key) else { return }

        let flow: String
        switch data.flowType {
        case .migration: flow = "migration"
        case .upgrade:   flow = "upgrade"
        }
        let productId = data.productId
        let variantId = data.variantId
        Task {
            do {
                let backend = try makeBackend()
                try await backend.reportOfferViewed(
                    userId: uid, productId: productId,
                    sessionId: session, variantId: variantId, flowType: flow
                )
            } catch {
                ZSLogger.debug("[OfferManager] reportOfferViewed failed: \(error)", category: .migration)
            }
        }
    }

    // MARK: - Dismissal Persistence

    public static var isPermanentlyDismissed: Bool {
        UserDefaults.standard.bool(forKey: dismissedKeyPrefix)
    }

    public static func isPermanentlyDismissed(forUserId userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "\(dismissedKeyPrefix).\(userId)")
    }

    public static func setDismissed(_ dismissed: Bool, forUserId userId: String) {
        UserDefaults.standard.set(dismissed, forKey: "\(dismissedKeyPrefix).\(userId)")
    }

    public static func resetDismissedState() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(dismissedKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Synthesizes a virtual active StoreKit ``Entitlement`` for demo mode from
    /// the server-configured migration prompt. Picks the first product in the
    /// prompt's `eligibleProductIds`. Returns `nil` if the prompt is missing
    /// or has no eligible products.
    ///
    /// Used only by the legacy-migration fallback path (``resolveFromMigration(_:iap:)``)
    /// in ``evaluateEligibility()``. The unified offer path (``resolveFromOffer(_:iap:)``)
    /// doesn't need a synthesizer because the server already returned a
    /// resolved offer payload.
    ///
    /// The synthetic entitlement's `purchasedAt` is 60 days in the past so any
    /// reasonable min-tenure check that slipped past the demo bypass would still
    /// pass; `expiresAt` is 30 days in the future so the downstream migration
    /// flow sees it as active.
    internal static func synthesizeDemoEntitlement(from prompt: MigrationPrompt?) -> Entitlement? {
        guard let prompt else { return nil }
        guard let productId = prompt.eligibleProductIds.first else { return nil }
        let now = Date()
        return Entitlement(
            id: "demo-synth-\(productId)",
            productId: productId,
            source: .storeKit,
            isActive: true,
            status: .active,
            expiresAt: now.addingTimeInterval(30 * 86_400),
            willRenew: true,
            // Intentional: matches `purchasedAt` exactly. A real StoreKit
            // entitlement's originalPurchaseDate equals purchasedAt for the
            // first transaction in a subscription group, so the synthesized
            // demo entitlement mirrors that shape.
            purchasedAt: now.addingTimeInterval(-60 * 86_400),
            storekitOriginalTransactionId: nil,
            originalPurchaseDate: now.addingTimeInterval(-60 * 86_400)
        )
    }

    #if DEBUG
    /// Test-only: force the manager into a given state. Never call from app code.
    internal func _setStateForTesting(_ newState: Offer.State) {
        state = newState
    }

    /// Test-only: inject offer data without round-tripping through the
    /// eligibility check (which requires network + a configured backend).
    /// Never call from app code.
    internal func _setOfferDataForTesting(_ data: Offer.OfferData?) {
        offerData = data
    }
    #endif
}
