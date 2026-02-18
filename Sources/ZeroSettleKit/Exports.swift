//
//  IAPExports.swift
//  ZeroSettleKit
//
//  Public exports for Merchant of Record checkout.
//

import Foundation

#if canImport(ZeroSettleCore)
@_implementationOnly import ZeroSettleCore
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
//   - ZSProduct.ProductType
//   - Price
//
// From Models/ProductCatalog.swift:
//   - ProductCatalog
//
// From Models/Transaction.swift:
//   - ZSTransaction
//   - ZSTransaction.Status
//
// From Models/Entitlement.swift:
//   - Entitlement
//   - Entitlement.Source
//
// From Models/Promotion.swift:
//   - Promotion
//   - Promotion.Kind
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
// From Models/CancelFlow.swift:
//   - CancelFlow (namespace enum)
//   - CancelFlow.Config
//   - CancelFlow.Question
//   - CancelFlow.QuestionType
//   - CancelFlow.Option
//   - CancelFlow.Offer
//   - CancelFlow.Result
//
// From UI/CancelFlowSheet.swift:
//   - View.zsCancelFlow(isPresented:productId:userId:onResult:)
//
// From StoreKit/StoreKitManager.swift:
//   - StoreKitPurchaseError
