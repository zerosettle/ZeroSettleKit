//
//  Entitlement+Merge.swift
//  ZeroSettleKit
//
//  Pure helpers for merging entitlement lists.
//

import Foundation

enum EntitlementMerge {
    /// Prefix used by `appendLocalEntitlement(for:)` when fabricating an
    /// in-memory entitlement for a checkout transaction the backend won't
    /// persist (consumables, or a pre-webhook race). Callers that rebuild
    /// the entitlement list from backend+StoreKit sources must preserve
    /// these, otherwise `newConsumableEntitlements(excluding:)` loses them
    /// before the host app has a chance to observe them.
    static let localFallbackIdPrefix = "web_"

    /// Merge locally-appended fallback entitlements from `prior` into `fresh`,
    /// keeping only those whose id is not already represented in `fresh`.
    ///
    /// A "local fallback" is any entitlement whose id starts with
    /// ``localFallbackIdPrefix``. These are typically consumables that the
    /// backend does not persist as an ``EntitlementState`` — the SDK appends
    /// them in-memory after a successful checkout so the host app can
    /// credit tokens before the list is refreshed.
    ///
    /// - Parameters:
    ///   - fresh: entitlements just fetched from StoreKit + backend.
    ///   - prior: the entitlement list that was in memory before the refresh.
    /// - Returns: ``fresh`` concatenated with any ``prior`` fallbacks whose
    ///   ids are not already present in ``fresh``.
    static func preservingLocalFallbacks(
        fresh: [Entitlement],
        prior: [Entitlement]
    ) -> [Entitlement] {
        let freshIds = Set(fresh.map(\.id))
        let preserved = prior.filter { entitlement in
            entitlement.id.hasPrefix(localFallbackIdPrefix)
                && !freshIds.contains(entitlement.id)
        }
        return fresh + preserved
    }
}
