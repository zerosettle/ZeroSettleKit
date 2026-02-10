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
//   - ZSError
//   - CheckoutFailure
//   - APIErrorDetail
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
// From UI/ZSPaymentSheet.swift:
//   - ZSPaymentSheet
//   - PaymentSheetError
//   - PaymentFailureDetail
//
// From StoreKit/StoreKitManager.swift:
//   - StoreKitPurchaseError
//
