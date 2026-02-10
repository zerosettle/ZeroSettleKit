//
//  IAPExports.swift
//  ZeroSettleKit
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
// From ZeroSettle.swift:
//   - ZeroSettle (main class)
//   - ZSError (unified error type)
//   - CheckoutFailure (checkout failure reasons)
//   - APIErrorDetail (structured API error detail)
//
// From ZeroSettleDelegate.swift:
//   - ZeroSettleDelegate
//
// From Models/Product.swift:
//   - ZSProduct (includes savingsPercent, storeKitPrice, storeKitAvailable)
//   - ZSProductType
//   - Price
//
// From Models/ProductCatalog.swift:
//   - ProductCatalog
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
//   - PaymentSheetError
//   - PaymentFailureDetail
//
// From UI/ZSManageSubscription.swift:
//   - View.zsManageSubscription(isPresented:userId:)
//
// From StoreKit/StoreKitManager.swift:
//   - StoreKitPurchaseError
