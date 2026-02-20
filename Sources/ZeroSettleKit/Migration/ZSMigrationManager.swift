//
//  ZSMigrationManager.swift
//  ZeroSettleKit
//
//  Observable manager for the StoreKit → web checkout migration flow.
//  Extracts business logic from ZSMigrateTipView so developers can
//  build custom migration UIs while reusing eligibility, state transitions,
//  and checkout orchestration.
//

import Foundation
import Combine
import SwiftUI
import StoreKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Manages the migration offer lifecycle for a single user.
///
/// Use this as a `@StateObject` to observe migration eligibility and drive
/// custom UIs, or let ``ZSMigrateTipView`` use it internally.
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
        ZSLogger.info("[ZSMigrationManager] resetDismissedState() called — clearing persisted dismissal", category: .iap)
        isPermanentlyDismissed = false
    }

    // MARK: - Private

    private var cancellable: AnyCancellable?

    // MARK: - Initialization

    /// Creates a migration manager for the given user.
    ///
    /// The manager immediately evaluates eligibility based on the current state
    /// of ``ZeroSettle/shared`` and re-evaluates whenever it publishes changes.
    ///
    /// - Parameter userId: Your app's user identifier
    public init(userId: String) {
        self.userId = userId
        ZSLogger.info("[ZSMigrationManager] init(userId: \"\(userId)\")", category: .iap)

        // Evaluate immediately
        evaluateEligibility()

        // Re-evaluate when ZeroSettle publishes changes (entitlements, config, bootstrap)
        cancellable = ZeroSettle.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change, so dispatch to next run loop
            Task { @MainActor [weak self] in
                self?.evaluateEligibility()
            }
        }
        ZSLogger.info("[ZSMigrationManager] Subscribed to ZeroSettle.shared.objectWillChange for re-evaluation", category: .iap)
    }

    // MARK: - Eligibility

    /// Re-evaluates eligibility. Only runs when state is `.ineligible` or `.eligible`
    /// (mid-flow states are locked to prevent disruption).
    private func evaluateEligibility() {
        // Demo mode: force out of dismissed state so re-evaluation can proceed
        if Self.demoMode && state == .dismissed {
            ZSLogger.info("[ZSMigrationManager] Demo mode — resetting dismissed state", category: .iap)
            state = .loading
        }

        let previousState = state

        // Don't re-evaluate during active flow
        guard state == .loading || state == .ineligible || state == .eligible else {
            ZSLogger.debug("[ZSMigrationManager] evaluateEligibility() skipped — state is .\(state) (mid-flow locked)", category: .iap)
            return
        }

        let iap = ZeroSettle.shared

        ZSLogger.info("[ZSMigrationManager] evaluateEligibility() running — currentState=.\(state), isBootstrapped=\(iap.isBootstrapped), isConfigured=\(iap.isConfigured), isPermanentlyDismissed=\(Self.isPermanentlyDismissed), isSandbox=\(iap.isSandbox), demoMode=\(Self.demoMode)", category: .iap)

        // Must be bootstrapped — stay in .loading until bootstrap completes
        guard iap.isBootstrapped else {
            state = .loading
            offerData = nil
            ZSLogger.info("[ZSMigrationManager] → .loading — waiting for bootstrap", category: .iap)
            return
        }

        // Demo mode: skip dismissal check, entitlement checks, and synthesize a demo offer
        if Self.demoMode {
            ZSLogger.info("[ZSMigrationManager] 🎭 Demo mode active — skipping dismissal and entitlement checks", category: .iap)

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
                activeStoreKitProductId: "wizzGoldWeekly"
            )

            state = .eligible
            offerData = data
            ZSLogger.info("[ZSMigrationManager] .\(previousState) → .eligible — demo mode (productId=wizzGoldWeekly, discount=15%, freeTrialDays=7)", category: .iap)
            return
        }

        // Must not be permanently dismissed
        guard !Self.isPermanentlyDismissed else {
            let changed = state != .dismissed
            state = .dismissed
            offerData = nil
            ZSLogger.info("[ZSMigrationManager] → .dismissed — permanently dismissed via UserDefaults\(changed ? "" : " (already dismissed)")", category: .iap)
            return
        }

        // Log full entitlement snapshot for debugging
        let entitlementSummary = iap.entitlements.map {
            "[\($0.productId) source=\($0.source.rawValue) active=\($0.isActive) expires=\($0.expiresAt?.description ?? "nil")]"
        }.joined(separator: ", ")
        ZSLogger.info("[ZSMigrationManager] Entitlements (\(iap.entitlements.count)): \(entitlementSummary.isEmpty ? "(none)" : entitlementSummary)", category: .iap)

        // Must have an active StoreKit subscription
        guard let activeStoreKitEntitlement = iap.entitlements.first(where: {
            $0.source == .storeKit && $0.isActive
        }) else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[ZSMigrationManager] → .ineligible — no active StoreKit entitlement found", category: .iap)
            return
        }
        ZSLogger.info("[ZSMigrationManager] Active StoreKit entitlement: productId=\(activeStoreKitEntitlement.productId), expiresAt=\(activeStoreKitEntitlement.expiresAt?.description ?? "nil")", category: .iap)

        // Must NOT already have an active web entitlement
        let webEntitlements = iap.entitlements.filter { $0.source == .webCheckout }
        let activeWebEntitlements = webEntitlements.filter { $0.isActive }
        ZSLogger.info("[ZSMigrationManager] Web entitlements: \(webEntitlements.count) total, \(activeWebEntitlements.count) active", category: .iap)

        guard activeWebEntitlements.isEmpty else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[ZSMigrationManager] → .ineligible — user already has active web checkout entitlement: \(activeWebEntitlements.map { $0.productId })", category: .iap)
            return
        }

        // Resolve migration prompt.
        // In sandbox mode: synthesize a prompt so developers can test without a backend campaign.
        // In live mode: requires the backend to return a migration prompt.
        let backendMigration = iap.remoteConfig?.migration
        ZSLogger.info("[ZSMigrationManager] remoteConfig.migration=\(backendMigration != nil ? "present(productId=\(backendMigration!.productId), discount=\(backendMigration!.discountPercent)%)" : "nil"), isSandbox=\(iap.isSandbox)", category: .iap)

        guard let prompt = resolveMigrationPrompt(
            activeStoreKitProductId: activeStoreKitEntitlement.productId
        ) else {
            state = .ineligible
            offerData = nil
            ZSLogger.info("[ZSMigrationManager] → .ineligible — no migration prompt (backend=nil, isSandbox=\(iap.isSandbox))", category: .iap)
            return
        }

        // Compute free trial days from StoreKit expiration
        let freeTrialDays = computeFreeTrialDays(from: activeStoreKitEntitlement)

        let data = MigrationOffer.OfferData(
            prompt: prompt,
            freeTrialDays: freeTrialDays,
            activeStoreKitProductId: activeStoreKitEntitlement.productId
        )

        state = .eligible
        offerData = data

        let promptSource = iap.remoteConfig?.migration != nil ? "backend" : "sandbox"
        ZSLogger.info("[ZSMigrationManager] .\(previousState) → .eligible — productId=\(data.activeStoreKitProductId), discount=\(prompt.discountPercent)%, freeTrialDays=\(freeTrialDays), promptSource=\(promptSource), title=\"\(prompt.title)\"", category: .iap)
    }

    /// Resolves the migration prompt from backend config or synthesizes one in sandbox mode.
    private func resolveMigrationPrompt(activeStoreKitProductId: String) -> MigrationPrompt? {
        let iap = ZeroSettle.shared

        // Use backend-provided prompt if available
        if let backendPrompt = iap.remoteConfig?.migration {
            ZSLogger.debug("[ZSMigrationManager] Using backend migration prompt: productId=\(backendPrompt.productId), discount=\(backendPrompt.discountPercent)%", category: .iap)
            return backendPrompt
        }

        // In sandbox mode, synthesize a prompt so developers can always test the flow
        if iap.isSandbox {
            ZSLogger.debug("[ZSMigrationManager] Sandbox mode — synthesizing migration prompt for productId=\(activeStoreKitProductId)", category: .iap)
            return MigrationPrompt(
                productId: activeStoreKitProductId,
                discountPercent: 15,
                title: "Switch & Save",
                message: "Switch to direct billing and get 15% off forever. Same features, fewer platform fees.",
                ctaText: "Save 15% Forever"
            )
        }

        ZSLogger.debug("[ZSMigrationManager] No migration prompt: backend migration=nil, isSandbox=false", category: .iap)
        return nil
    }

    /// Computes the number of free trial days from a StoreKit entitlement's expiration date.
    private func computeFreeTrialDays(from entitlement: Entitlement) -> Int {
        guard let expiresAt = entitlement.expiresAt else {
            ZSLogger.debug("[ZSMigrationManager] No expiresAt on entitlement \(entitlement.productId), freeTrialDays=0", category: .iap)
            return 0
        }
        let components = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt)
        let days = max(0, components.day ?? 0)
        ZSLogger.debug("[ZSMigrationManager] Computed freeTrialDays=\(days) (expiresAt=\(expiresAt))", category: .iap)
        return days
    }

    // MARK: - State Transitions

    /// Transition from `.eligible` to `.presented`.
    ///
    /// Call this when you show the migration offer UI or begin the checkout flow.
    public func present() {
        guard state == .eligible else {
            ZSLogger.info("[ZSMigrationManager] present() ignored — state is .\(state), expected .eligible", category: .iap)
            return
        }
        state = .presented
        ZSLogger.info("[ZSMigrationManager] .eligible → .presented", category: .iap)
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
            ZSLogger.error("[ZSMigrationManager] startCheckout() failed — no offerData available", category: .iap)
            checkoutError = ZSError.notConfigured
            return nil
        }

        if state == .eligible {
            state = .presented
            ZSLogger.info("[ZSMigrationManager] .eligible → .presented (via startCheckout)", category: .iap)
        }

        checkoutError = nil
        isLoading = true

        ZSLogger.info("[ZSMigrationManager] Creating payment intent: productId=\(offerData.prompt.productId), userId=\(userId), freeTrialDays=\(offerData.freeTrialDays)", category: .iap)

        do {
            let backend = try makeBackend()
            let paymentIntent = try await backend.createPaymentIntent(
                productId: offerData.prompt.productId,
                userId: userId,
                freeTrialDays: offerData.freeTrialDays
            )

            isLoading = false
            let url = URL(string: paymentIntent.checkoutUrl)
            ZSLogger.info("[ZSMigrationManager] Payment intent created — checkoutUrl=\(paymentIntent.checkoutUrl)", category: .iap)
            return url
        } catch {
            checkoutError = error
            isLoading = false
            ZSLogger.error("[ZSMigrationManager] Payment intent failed: \(error)", category: .iap)
            return nil
        }
    }

    /// Mark the web checkout as succeeded.
    ///
    /// Transitions from `.presented` to `.accepted` and fires migration conversion tracking.
    public func markCheckoutSucceeded() {
        guard state == .presented else {
            ZSLogger.info("[ZSMigrationManager] markCheckoutSucceeded() ignored — state is .\(state), expected .presented", category: .iap)
            return
        }
        state = .accepted
        ZSLogger.info("[ZSMigrationManager] .presented → .accepted — checkout succeeded for userId=\(userId)", category: .iap)

        // Fire-and-forget conversion tracking
        Task {
            ZSLogger.info("[ZSMigrationManager] Tracking migration conversion for userId=\(userId)", category: .iap)
            do {
                try await ZeroSettle.shared.trackMigrationConversion(userId: userId)
                ZSLogger.info("[ZSMigrationManager] Migration conversion tracked successfully", category: .iap)
            } catch {
                ZSLogger.error("[ZSMigrationManager] Migration conversion tracking failed: \(error)", category: .iap)
            }
        }
    }

    /// Open the Apple subscription management sheet, then transition to `.completed`.
    ///
    /// After the sheet dismisses, the state moves to `.completed` to indicate the
    /// full migration flow is done.
    public func showAppleSubscriptionManagement() async {
        guard state == .accepted else {
            ZSLogger.info("[ZSMigrationManager] showAppleSubscriptionManagement() ignored — state is .\(state), expected .accepted", category: .iap)
            return
        }

        ZSLogger.info("[ZSMigrationManager] Opening Apple subscription management sheet...", category: .iap)

        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                ZSLogger.error("[ZSMigrationManager] No UIWindowScene available — cannot open subscription management", category: .iap)
                return
            }
            try await AppStore.showManageSubscriptions(in: windowScene)
            state = .completed
            ZSLogger.info("[ZSMigrationManager] .accepted → .completed — subscription management sheet dismissed", category: .iap)
        } catch {
            ZSLogger.error("[ZSMigrationManager] Failed to open subscription management: \(error)", category: .iap)
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
        ZSLogger.info("[ZSMigrationManager] .\(previous) → .dismissed — persisted to UserDefaults", category: .iap)
    }

    // MARK: - Backend Helper

    private func makeBackend() throws -> Backend {
        guard let config = ZeroSettle.shared.currentConfig,
              let baseURL = ZeroSettle.shared.effectiveBaseURL else {
            ZSLogger.error("[ZSMigrationManager] makeBackend() failed — SDK not configured", category: .iap)
            throw ZSError.notConfigured
        }
        return Backend(baseURL: baseURL, publishableKey: config.publishableKey)
    }
}
