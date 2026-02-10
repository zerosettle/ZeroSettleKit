//
//  IAPExports.swift
//  ZeroSettleIAP
//
//  Public exports for Merchant of Record checkout.
//

import Foundation

#if canImport(ZeroSettleCore)
@_exported import ZeroSettleCore
#endif

// MARK: - Public Types
//
// The following types are publicly available:
//
// From ZeroSettleIAP.swift:
//   - ZeroSettleIAP (main class)
//   - ZSError (unified error type; typealias ZeroSettleIAPError = ZSError)
//   - CheckoutFailure (checkout failure reasons; typealias CheckoutFailureReason = CheckoutFailure)
//   - APIErrorDetail
//
// From ZeroSettleIAPDelegate.swift:
//   - ZeroSettleIAPDelegate
//
// From Models/Product.swift:
//   - ZSProduct
//   - ZSProductType
//   - Price
//
// From Models/Transaction.swift:
//   - ZSTransaction
//   - TransactionStatus
//
// From Models/Entitlement.swift:
//   - Entitlement
//   - EntitlementSource
//
// From Models/Promotion.swift:
//   - Promotion
//   - PromotionType
//
// From Models/ProductCatalog.swift:
//   - ProductCatalog
//
// From Models/RemoteConfig.swift:
//   - CheckoutType
//   - CheckoutConfig
//   - JurisdictionCheckoutConfig
//   - MigrationPrompt
//   - RemoteConfig
//   - Jurisdiction
//
// From UI/ZSPaymentSheet.swift:
//   - ZSPaymentSheet
//   - PaymentSheetError (deprecated — prefer ZSError)
//   - PaymentFailureDetail
//
// From UI/ZSManageSubscription.swift:
//   - View.zsManageSubscription(isPresented:userId:)
//
// From StoreKit/StoreKitManager.swift:
//   - StoreKitPurchaseError (deprecated — prefer ZSError)
