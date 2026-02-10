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
//   - ZSError (canonical error type)
//   - CheckoutFailure (checkout failure reasons)
//   - APIErrorDetail (structured API error detail)
//   - ZeroSettleIAPError (deprecated typealias → ZSError)
//   - CheckoutFailureReason (deprecated typealias → CheckoutFailure)
//
// From ZeroSettleIAPDelegate.swift:
//   - ZeroSettleIAPDelegate
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
//
// From Models/RemoteConfig.swift:
//   - CheckoutType
//   - CheckoutConfig
//   - MigrationPrompt
//   - RemoteConfig
//
// From Checkout/ZeroSettleCheckoutView.swift:
//   - ZeroSettleCheckoutView (deprecated → ZSPaymentSheet)
//
// From UI/ZSPaymentSheet.swift:
//   - ZSPaymentSheet
//   - PaymentSheetError
//   - PaymentFailureDetail
//
// From StoreKit/StoreKitManager.swift:
//   - StoreKitPurchaseError
//
