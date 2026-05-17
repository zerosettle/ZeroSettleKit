//
//  ZSProduct+Lookup.swift
//  ZeroSettleKit
//
//  Case-insensitive id lookup helpers for `[ZSProduct]`.
//
//  Why: the backend's `Product.reference_id` lookup is case-insensitive
//  (UNIQUE(LOWER(reference_id)) constraint on the column). Apple's StoreKit
//  ids ARE case-sensitive in practice, but developers commonly register a
//  product in mixed case in App Store Connect and reference it in a different
//  case in code (or vice-versa). Diverging from the backend on case-handling
//  produces "product not found" errors that the backend would resolve.
//
//  Five call-sites in the SDK need this exact behaviour:
//    * `ZeroSettle.product(for:)` (public convenience lookup)
//    * `ZeroSettle.purchase(productId:userId:)` (web checkout entry)
//    * `ZeroSettle.purchaseViaStoreKit(productId:userId:)` (native entry)
//    * `ZSOfferManager.resolveFromOffer(_:iap:)` (offer catalogue gate)
//    * `ZSMigrationManager.evaluateEligibility(...)` (migration target check)
//
//  Centralising the comparator here keeps the case-handling rule in one
//  place so future call-sites can't accidentally drift back to `==`.
//

import Foundation

extension Array where Element == ZSProduct {

    /// Returns the first product whose `id` matches `id` case-insensitively,
    /// or `nil` if no product matches. Mirrors backend `reference_id` lookup
    /// semantics (UNIQUE(LOWER(reference_id))).
    func firstMatching(id: String) -> ZSProduct? {
        first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Whether any product's `id` matches `id` case-insensitively. Convenience
    /// wrapper around ``firstMatching(id:)`` for use-sites that only need a
    /// presence check.
    func containsMatching(id: String) -> Bool {
        contains { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}
