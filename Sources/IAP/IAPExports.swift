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
//   - ZeroSettleIAPError
//
// From ZeroSettleIAPDelegate.swift:
//   - ZeroSettleIAPDelegate
//
// From Models/Product.swift:
//   - Product
//   - ProductType
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
//
// From Models/RemoteConfig.swift:
//   - CheckoutType
//   - CheckoutConfig
//   - MigrationPrompt
//   - RemoteConfig
//
// From Checkout/ZeroSettleCheckoutView.swift:
//   - ZeroSettleCheckoutView
//   - CheckoutError
