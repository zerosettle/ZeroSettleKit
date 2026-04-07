import Foundation
import Combine
import StoreKit

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
@MainActor
public final class ZSOfferManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: Offer.State = .loading
    @Published public private(set) var offerData: Offer.OfferData?
    @Published public private(set) var checkoutError: Error?
    @Published public private(set) var isLoading = false
    @Published public private(set) var storekitCancelRequired = false

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
    private var observation: AnyCancellable?
    private var preloadTask: Task<URL?, Never>?

    // Persistence keys
    private static let dismissedKeyPrefix = "com.zerosettle.offerTipDismissed"

    // MARK: - Init

    public init(userId: String, stripeCustomerId: String? = nil) {
        self.userId = userId
        self.stripeCustomerId = stripeCustomerId
        startObserving()
    }

    // MARK: - Observation

    private func startObserving() {
        // Re-evaluate eligibility when ZeroSettle state changes
        observation = NotificationCenter.default.publisher(
            for: NSNotification.Name("ZeroSettleStateDidChange")
        ).receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateEligibility()
            }
        }

        // Initial evaluation
        Task { @MainActor [weak self] in
            self?.evaluateEligibility()
        }
    }

    // MARK: - Eligibility

    private func evaluateEligibility() {
        // Don't re-evaluate mid-flow states
        guard [.loading, .ineligible, .eligible].contains(state) else { return }

        let iap = ZeroSettle.shared
        guard iap.isBootstrapped else { return }

        // Check dismissal
        if Self.isPermanentlyDismissed(forUserId: userId) {
            state = .ineligible
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
        // Rollout cohort check
        if let rollout = offer.rolloutPercent, rollout < 100 {
            let bucketKey = "\(userId):offer"
            let hash = bucketKey.utf8.reduce(0) { $0 &+ Int($1) }
            let bucket = abs(hash) % 100
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
                        perProductPrompts: nil
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
        // Legacy path: requires StoreKit subscription (same as ZSMigrationManager)
        let skEntitlements = iap.entitlements.filter { $0.source == .storeKit && $0.isActive }
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
            perProductPrompts: nil
        )
        state = .eligible
    }

    // MARK: - Public Methods

    /// Transition from `.eligible` → `.presented`.
    public func present() {
        guard state == .eligible else { return }
        state = .presented
    }

    /// Start the checkout flow. Returns the checkout URL for WebView,
    /// or nil for web-to-web upgrades (handled internally).
    public func startCheckout(stripeCustomerId: String? = nil) async -> URL? {
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

    /// Mark checkout as succeeded. Handles post-checkout state transitions.
    public func markCheckoutSucceeded(transactionId: String? = nil) async {
        guard let data = offerData else { return }

        checkoutTransactionId = transactionId

        if data.needsAppleCancel {
            storekitCancelRequired = true
            state = .accepted
        } else {
            // Web-to-web: skip Apple cancel, go straight to completed
            state = .completed
        }

        // Refresh entitlements
        if let userId = offerData?.flowType == .migration ? self.userId : nil {
            try? await ZeroSettle.shared.trackMigrationConversion(userId: userId)
        }
    }

    /// Open Apple subscription management sheet.
    public func showAppleSubscriptionManagement() async {
        #if os(iOS)
        if #available(iOS 15.0, *) {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }

            do {
                try await AppStore.showManageSubscriptions(in: windowScene)
            } catch {
                ZSLogger.error("[OfferManager] Failed to open subscription management: \(error)", category: .migration)
            }
        }
        #endif

        // Check cancellation status via backend
        storekitCancelRequired = false
        state = .completed
    }

    /// Dismiss the offer and persist dismissal.
    public func dismiss() {
        state = .dismissed
        Self.setDismissed(true, forUserId: userId)
    }

    /// Preload checkout session for faster presentation.
    public func preloadCheckout(stripeCustomerId: String? = nil) async -> URL? {
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
            let skEntitlement = ZeroSettle.shared.entitlements.first { $0.source == .storeKit && $0.isActive }
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
        return URL(string: checkout.checkoutUrl)!
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
        guard let iap = ZeroSettle.shared as? ZeroSettle,
              iap.isConfigured else {
            throw ZeroSettleError.notConfigured
        }
        return iap.backend
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
}
