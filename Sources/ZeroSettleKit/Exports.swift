//
//  Exports.swift
//  ZeroSettleKit
//
//  Public API manifest and deprecated compatibility aliases.
//

import Foundation
import SwiftUI

// MARK: - Public Types
//
// The following types are publicly available:
//
// From ZeroSettle.swift:
//   - ZeroSettle (main class)
//   - ZeroSettleError (unified error type)
//   - CheckoutFailure (checkout failure reasons)
//   - APIErrorDetail (structured API error detail)
//
// From ZeroSettleDelegate.swift:
//   - ZeroSettleDelegate
//
// From Models/ZSProduct.swift:
//   - ZSProduct (includes savingsPercent, storeKitPrice, storeKitAvailable)
//   - ZSProduct.ProductType
//   - Price
//
// From Models/ProductCatalog.swift:
//   - ProductCatalog
//
// From Models/Transaction.swift:
//   - CheckoutTransaction
//   - CheckoutTransaction.Status
//
// From Models/Entitlement.swift:
//   - Entitlement
//   - Entitlement.Source
//   - Entitlement.Status
//
// From Models/Promotion.swift:
//   - Promotion
//   - Promotion.Kind
//
// From Models/RemoteConfig.swift:
//   - CheckoutType
//   - CheckoutConfig
//   - JurisdictionCheckoutConfig
//   - MigrationPrompt
//   - RemoteConfig
//   - Jurisdiction
//
// From Models/CancelFlow.swift:
//   - CancelFlow (namespace enum)
//   - CancelFlow.Config
//   - CancelFlow.Question
//   - CancelFlow.QuestionType
//   - CancelFlow.Option
//   - CancelFlow.Offer
//   - CancelFlow.OfferType
//   - CancelFlow.PauseConfig
//   - CancelFlow.PauseOption
//   - CancelFlow.PauseOption.DurationType
//   - CancelFlow.Result (includes .paused(resumesAt:))
//
// From Models/UpgradeOffer.swift:
//   - UpgradeOffer (namespace enum)
//   - UpgradeOffer.Config
//   - UpgradeOffer.ProductInfo
//   - UpgradeOffer.Proration
//   - UpgradeOffer.Display
//   - UpgradeOffer.IneligibilityReason
//   - UpgradeOffer.Result
//
// From UI/ZSPaymentSheet.swift:
//   - CheckoutSheet
//
// From UI/ZSManageSubscriptionSheet.swift:
//   - RetentionSheet
//   - RetentionResult
//
// From Migration/ZSMigrationManager.swift:
//   - ZSMigrationManager
//
// From UI/ZSMigrateTipView.swift:
//   - MigrationTipView
//   - MigrationTipView.Event
//
// View Modifiers (on SwiftUI View):
//   - .checkoutSheet(isPresented:product:userId:dismissible:preload:onComplete:)
//   - .checkoutSheet(isPresented:product:userId:dismissible:preload:header:onComplete:)
//   - .checkoutSheet(item:userId:dismissible:preload:onComplete:)
//   - .checkoutSheet(item:userId:dismissible:preload:header:onComplete:)
//   - .retentionSheet(isPresented:onResult:)
//   - .cancelFlow(isPresented:productId:userId:onResult:)
//   - .upgradeOffer(isPresented:productId:userId:onResult:)
//   - .zeroSettleHandler()
//

// MARK: - Deprecated Type Aliases
//
// These aliases provide source compatibility for code written against
// the pre-1.0 API. They will be removed in a future major version.

@available(*, deprecated, renamed: "CheckoutTransaction")
public typealias ZSTransaction = CheckoutTransaction

@available(*, deprecated, renamed: "ZeroSettleError")
public typealias ZSError = ZeroSettleError

@available(*, deprecated, renamed: "CheckoutSheet")
public typealias ZSPaymentSheet = CheckoutSheet

@available(*, deprecated, renamed: "ZSMigrationManager")
public typealias MigrationManager = ZSMigrationManager

@available(*, deprecated, renamed: "MigrationTipView")
public typealias ZSMigrateTipView = MigrationTipView

@available(*, deprecated, renamed: "RetentionSheet")
public typealias ZSManageSubscriptionSheet = RetentionSheet

@available(*, deprecated, renamed: "RetentionResult")
public typealias ZSManageSubscriptionResult = RetentionResult

// MARK: - Deprecated View Modifier Forwarding

extension View {

    /// Deprecated: use `.checkoutSheet(isPresented:product:userId:...)` instead.
    @available(*, deprecated, renamed: "checkoutSheet(isPresented:product:userId:dismissible:preload:onComplete:)")
    public func zsPaymentSheet(
        isPresented: Binding<Bool>,
        product: ZSProduct,
        userId: String? = nil,
        freeTrialDays: Int = 0,
        dismissible: Bool = true,
        preload: PaymentSheetPreload? = nil,
        onComplete: @escaping (Result<CheckoutTransaction, Error>) -> Void
    ) -> some View {
        checkoutSheet(
            isPresented: isPresented,
            product: product,
            userId: userId,
            dismissible: dismissible,
            preload: preload,
            onComplete: onComplete
        )
    }

    /// Deprecated: use `.retentionSheet(isPresented:onResult:)` instead.
    @available(*, deprecated, renamed: "retentionSheet(isPresented:onResult:)")
    public func zsManageSubscriptionSheet(
        isPresented: Binding<Bool>,
        onResult: @escaping (RetentionResult) -> Void
    ) -> some View {
        retentionSheet(isPresented: isPresented, onResult: onResult)
    }

    /// Deprecated: use `.cancelFlow(isPresented:productId:userId:onResult:)` instead.
    @available(*, deprecated, renamed: "cancelFlow(isPresented:productId:userId:onResult:)")
    public func zsCancelFlow(
        isPresented: Binding<Bool>,
        productId: String,
        userId: String,
        onResult: @escaping (CancelFlow.Result) -> Void = { _ in }
    ) -> some View {
        cancelFlow(isPresented: isPresented, productId: productId, userId: userId, onResult: onResult)
    }

    /// Deprecated: use `.upgradeOffer(isPresented:productId:userId:onResult:)` instead.
    @available(*, deprecated, renamed: "upgradeOffer(isPresented:productId:userId:onResult:)")
    public func zsUpgradeOffer(
        isPresented: Binding<Bool>,
        productId: String? = nil,
        userId: String,
        onResult: @escaping (UpgradeOffer.Result) -> Void = { _ in }
    ) -> some View {
        upgradeOffer(isPresented: isPresented, productId: productId, userId: userId, onResult: onResult)
    }
}

// MARK: - Deprecated Method Forwarding

extension ZeroSettle {

    /// Deprecated: use ``migrationManager(for:)`` instead.
    @available(*, deprecated, renamed: "migrationManager(for:)")
    public func getOrCreateMigrationManager(userId: String) -> ZSMigrationManager {
        migrationManager(for: userId)
    }

    /// Removed: use ``presentCancelFlow(productId:userId:)`` for cancellation,
    /// or `AppStore.showManageSubscriptions(in:)` for Apple billing management.
    @available(*, unavailable, message: "Use presentCancelFlow(productId:userId:) for cancellation, or AppStore.showManageSubscriptions(in:) directly for Apple billing management.")
    public func openCustomerPortal(userId: String) async throws {
        fatalError()
    }

    /// Removed: use ``presentCancelFlow(productId:userId:)`` for cancellation,
    /// or `AppStore.showManageSubscriptions(in:)` for Apple billing management.
    @available(*, unavailable, message: "Use presentCancelFlow(productId:userId:) for cancellation, or AppStore.showManageSubscriptions(in:) directly for Apple billing management.")
    public func showManageSubscription(userId: String) async throws {
        fatalError()
    }

    /// Deprecated: use ``pauseSubscription(productId:userId:pauseDurationDays:)`` instead.
    @available(*, deprecated, message: "Use pauseSubscription(productId:userId:pauseDurationDays:) instead")
    public func pauseSubscription(productId: String, userId: String, pauseOptionId: Int) async throws -> Date? {
        let durationDays = cancelFlowConfig?.pause?.options
            .first(where: { $0.id == pauseOptionId })?.durationDays
        return try await pauseSubscription(
            productId: productId,
            userId: userId,
            pauseDurationDays: durationDays
        )
    }
}

// MARK: - Deprecated View Modifier Forwarding (Removed APIs)

extension View {

    /// Deprecated: use `.retentionSheet(isPresented:onResult:)` or `.cancelFlow(isPresented:productId:userId:onResult:)` instead.
    @available(*, deprecated, message: "Use .retentionSheet(isPresented:onResult:) or .cancelFlow(isPresented:productId:userId:onResult:) instead")
    public func manageSubscription(
        isPresented: Binding<Bool>,
        userId: String
    ) -> some View {
        retentionSheet(isPresented: isPresented, onResult: { _ in })
    }

    /// Deprecated: use `.retentionSheet(isPresented:onResult:)` or `.cancelFlow(isPresented:productId:userId:onResult:)` instead.
    @available(*, deprecated, message: "Use .retentionSheet(isPresented:onResult:) or .cancelFlow(isPresented:productId:userId:onResult:) instead")
    public func zsManageSubscription(
        isPresented: Binding<Bool>,
        userId: String
    ) -> some View {
        manageSubscription(isPresented: isPresented, userId: userId)
    }
}
