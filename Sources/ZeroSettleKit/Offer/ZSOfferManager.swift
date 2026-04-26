import Foundation
import StoreKit
import CryptoKit
internal import ZeroSettleCore

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
@MainActor
public final class ZSOfferManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: Offer.State = .loading
    @Published public private(set) var offerData: Offer.OfferData?
    @Published public private(set) var checkoutError: Error?
    @Published public private(set) var isLoading = false
    @Published public private(set) var storekitCancelRequired = false

    // MARK: - Demo Mode

    /// Previews the tenant-configured offer tip on a device without a sandbox StoreKit purchase.
    ///
    /// When `true`, ``evaluateEligibility()`` uses the tenant's real server-side
    /// offer (``Offer/OfferData``) — same title, message, CTA, discount, and
    /// `checkout_presentation` the end user would see in production — but bypasses
    /// gates that would otherwise require an active StoreKit or web subscription.
    ///
    /// ## Bypassed gates
    ///
    /// - active StoreKit subscription (for `needsAppleCancel` offers)
    /// - rollout bucket hash
    /// - min / max subscription-tenure
    /// - "already has active web subscription"
    ///
    /// ## Still enforced
    ///
    /// - SDK configured via ``ZeroSettle/configure(_:)`` and bootstrapped via ``ZeroSettle/bootstrap(userId:)``
    /// - Permanent dismissal
    /// - Server returned ``RemoteConfig/offer`` or ``RemoteConfig/migration``.
    ///   If the tenant's dashboard has no offer configured, demo mode resolves
    ///   to ``Offer/State/ineligible`` — there is no hardcoded fallback.
    ///
    /// ## Known limitation: upgrade preview
    ///
    /// Upgrade offers (``Offer/FlowType/upgradeStorekitToWeb`` and
    /// ``Offer/FlowType/upgradeWebToWeb``) are computed server-side from the
    /// user's current subscription. A user with no entitlements receives no
    /// offer from the server regardless of demo mode. To preview upgrade
    /// tips, a real sandbox StoreKit purchase is still required. Migration
    /// tips are previewable without a purchase because ``RemoteConfig/migration``
    /// is returned unconditionally when configured.
    ///
    /// ## Transactions are disabled in demo mode
    ///
    /// Tapping the tip's CTA while ``demoMode`` is `true` does **not** open
    /// checkout. The SDK sets ``showDemoModeAlert`` and leaves ``state`` at
    /// ``Offer/State/eligible``; the tip view renders a local alert explaining
    /// the block. No `PaymentIntent` or `SetupIntent` is created. To verify
    /// the real checkout flow, disable demo mode and complete a StoreKit
    /// sandbox purchase.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// #if DEBUG
    /// ZSOfferManager.demoMode = true
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
    /// - SeeAlso: ``showDemoModeAlert``. For the deprecated predecessor's
    ///   equivalent flag, see ``ZSMigrationManager/demoMode``.
    public static var demoMode: Bool = false {
        didSet {
            if demoMode && !oldValue {
                ZSLogger.info(
                    "[OfferManager] ⚠️ demoMode=true — migration-offer tips preview " +
                    "without any subscription; upgrade-offer tips still need a real " +
                    "subscription (server-driven). Checkout CTA is disabled to prevent " +
                    "real charges. Never ship with demoMode on.",
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

    /// The user ID this manager was created for.
    public let userId: String

    /// The resolved flow type (nil until eligible).
    public var flowType: Offer.FlowType? { offerData?.flowType }

    /// Whether the current offer requires Apple subscription cancellation.
    public var needsAppleCancel: Bool { offerData?.needsAppleCancel ?? false }

    /// The display copy from the server (nil until offer resolved).
    public var display: Offer.Display? { offerData?.display }

    // MARK: - Private State

    private var stripeCustomerId: String?
    private var checkoutTransactionId: String?
    private var preloadTask: Task<URL?, Never>?
    private var monitorObservationTask: Task<Void, Never>?

    // Persistence keys
    private static let dismissedKeyPrefix = "com.zerosettle.offerTipDismissed"

    /// Active StoreKit entitlements for the current user.
    /// Used to check migration eligibility and find subscription details.
    private var activeStoreKitEntitlements: [Entitlement] {
        ZeroSettle.shared.entitlements.filter { $0.source == .storeKit && $0.isActive }
    }

    // MARK: - Init

    public init(userId: String, stripeCustomerId: String? = nil) {
        self.userId = userId
        self.stripeCustomerId = stripeCustomerId
        startObserving()
        startMonitoringSubscriptionChanges()
    }

    deinit {
        monitorObservationTask?.cancel()
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
        let _diagOldState = state
        defer {
            ZSLogger.info(
                "[diag] evaluateEligibility outcome: \(_diagOldState) → \(self.state) demoMode=\(Self.demoMode) isBootstrapped=\(iap.isBootstrapped) hasOffer=\(iap.remoteConfig?.offer != nil) hasMigration=\(iap.remoteConfig?.migration != nil) webEnabled=\(iap.isWebCheckoutEnabled) jurisdiction=\(iap.effectiveJurisdiction.rawValue) entitlements=\(iap.entitlements.count) skEntitlements=\(self.activeStoreKitEntitlements.count)",
                category: .migration
            )
        }
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
        // Rollout cohort check (skipped in demo mode — devs always see their tip)
        if !Self.demoMode, let rollout = offer.rolloutPercent, rollout < 100 {
            let digest = SHA256.hash(data: Data(userId.utf8))
            let firstBytes = digest.prefix(4)
            let hashValue = firstBytes.reduce(0) { ($0 << 8) | UInt32($1) }
            let bucket = Int(hashValue % 100)
            if bucket >= rollout {
                state = .ineligible
                return
            }
        }

        // Verify target product exists in catalog
        let targetId = offer.checkoutProductId
        guard iap.products.contains(where: { $0.id == targetId }) else {
            ZSLogger.info("[OfferManager] Target product \(targetId) not found in catalog", category: .migration)
            state = .ineligible
            return
        }

        // Migration and storekit_to_web flows require an active StoreKit subscription
        // (skipped in demo mode — the dev is previewing without a real purchase).
        if !Self.demoMode, offer.needsAppleCancel {
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
        if Self.demoMode && skEntitlements.isEmpty {
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

    // MARK: - Public Methods

    /// Transition from `.eligible` → `.presented`.
    public func present() {
        guard state == .eligible else {
            ZSLogger.info("[OfferManager] present() skipped — state is \(state), expected .eligible", category: .migration)
            return
        }
        if Self.demoMode {
            showDemoModeAlert = true
            ZSLogger.info(
                "[OfferManager] CTA tap blocked: demoMode is true — alert shown, no checkout initiated",
                category: .migration
            )
            return
        }
        state = .presented
    }

    /// Start the checkout flow. Returns the checkout URL for WebView,
    /// or nil for web-to-web upgrades (handled internally).
    public func startCheckout(stripeCustomerId: String? = nil) async -> URL? {
        // Demo mode: never initiate a real PaymentIntent. The view layer
        // should already have short-circuited; this is defense in depth.
        if Self.demoMode { return nil }
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
                    stripeCustomerId: stripeCustomerId ?? self.stripeCustomerId
                )
                isLoading = false
                return url
            }
        } catch {
            checkoutError = error
            isLoading = false
            ZSLogger.error("[OfferManager] Checkout failed: \(error)", category: .migration)
            return nil
        }
    }

    /// Mark checkout as succeeded. Verifies transaction, refreshes entitlements,
    /// and handles post-checkout state transitions.
    public func markCheckoutSucceeded(transactionId: String? = nil) async {
        ZSLogger.info("[OfferManager] markCheckoutSucceeded called. state=\(state) needsAppleCancel=\(offerData?.needsAppleCancel ?? false)", category: .migration)
        guard state == .presented else {
            ZSLogger.error("[OfferManager] markCheckoutSucceeded SKIPPED — state is \(state), expected .presented", category: .migration)
            return
        }
        guard let data = offerData else { return }

        checkoutTransactionId = transactionId

        if data.needsAppleCancel {
            storekitCancelRequired = true
            state = .accepted
        } else {
            state = .completed
        }

        // Verify transaction and refresh entitlements
        if let transactionId {
            do {
                let backend = try makeBackend()
                let transaction = try await backend.verifyTransaction(transactionId: transactionId)
                await ZeroSettle.shared.delegate?.zeroSettleCheckoutDidComplete(transaction: transaction)
                await ZeroSettle.shared.refreshEntitlementsAfterCheckout(transaction: transaction)
            } catch {
                ZSLogger.error("[OfferManager] Transaction verification failed: \(error)", category: .migration)
            }
        }

        // Fire-and-forget conversion tracking (both migration and storekit_to_web upgrades)
        if data.flowType == .migration || data.upgradeType == .storekitToWeb {
            Task {
                do {
                    try await ZeroSettle.shared.trackMigrationConversion(userId: userId)
                } catch {
                    ZSLogger.error("[OfferManager] Conversion tracking failed: \(error)", category: .migration)
                }
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
        if Self.demoMode { return nil }
        guard let data = offerData else { return nil }

        // Web-to-web doesn't need preloading (no WebView)
        if data.upgradeType == .webToWeb { return nil }

        return try? await startWebViewCheckout(
            data: data,
            stripeCustomerId: stripeCustomerId ?? self.stripeCustomerId
        )
    }

    // MARK: - Private Checkout Helpers

    private func startWebViewCheckout(data: Offer.OfferData, stripeCustomerId: String?) async throws -> URL {
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
            storekitOriginalTransactionId: storekitOrigTxnId
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
    #endif
}
