//
//  ExternalPurchaseTokenProvider.swift
//  ZeroSettleKit
//
//  Mints Apple external-purchase tokens for compliance reporting.
//

import Foundation
import StoreKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Mints Apple external-purchase tokens for compliance reporting.
///
/// Invoked automatically inside `Backend.initiateCheckout` — no public API.
/// Returns nil whenever a token is not applicable (US storefront, ineligible
/// region, unsupported iOS, missing entitlement) or minting fails: checkout
/// must NEVER break because compliance minting failed (backend records the
/// transaction as token-less and surfaces it in the coverage dashboard).
///
/// Region → path mapping (see design doc 2026-06-09 §3/§4):
/// - EU / EEA-music / Japan, iOS 18.1+ → `ExternalPurchaseCustomLink.token(for:)`
///   (ACQUISITION first, SERVICES fallback; Japan uses LINK_OUT, iOS 26.4+).
/// - EEA on iOS 17.4–18.0 → `ExternalPurchase.presentNoticeSheet()` (the
///   token-bearing `.continuedWithExternalPurchaseToken` result and
///   `ExternalPurchase.canPresent` both require iOS 17.4 per SDK headers).
/// - US / everywhere else → nil (no entitlement, no report, no commission).
/// Korea/Netherlands: not in v1 (backend has no regime for them yet).
internal enum ExternalPurchaseTokenProvider {

    /// Alpha-3 storefront codes for the EU-27 (matches backend EU_COUNTRIES).
    static let euStorefronts: Set<String> = [
        "AUT", "BEL", "BGR", "CYP", "CZE", "DEU", "DNK", "EST", "ESP", "FIN",
        "FRA", "GRC", "HRV", "HUN", "IRL", "ITA", "LTU", "LUX", "LVA", "MLT",
        "NLD", "POL", "PRT", "ROU", "SWE", "SVN", "SVK",
    ]
    /// EEA = EU + Iceland, Norway, Liechtenstein.
    static let eeaStorefronts: Set<String> = euStorefronts.union(["ISL", "NOR", "LIE"])
    static let japanStorefront = "JPN"

    enum MintRegion: Equatable {
        case eu        // custom-link ACQUISITION/SERVICES
        case japan     // custom-link LINK_OUT (iOS 26.4+)
        case none      // no token applicable
    }

    /// Pure region gate — unit-testable.
    static func region(forStorefront storefront: String?) -> MintRegion {
        guard let code = storefront?.uppercased(), !code.isEmpty else { return .none }
        if code == japanStorefront { return .japan }
        if eeaStorefronts.contains(code) { return .eu }
        return .none
    }

    /// Mint a token for the current storefront, or nil when not applicable.
    /// Never throws into the checkout path.
    static func mintIfNeeded(storefront: String?) async -> String? {
        let region = region(forStorefront: storefront)
        guard region != .none else { return nil }

        #if os(iOS)
        // Modern custom-link path (iOS 18.1+).
        if #available(iOS 18.1, *) {
            do {
                let tokenTypes: [String]
                switch region {
                case .japan:
                    // Japan token(for:) types require iOS 26.4+; on older iOS
                    // fall through to nil (backend gates JP at 26.4 anyway).
                    if #available(iOS 26.4, *) { tokenTypes = ["LINK_OUT"] }
                    else { tokenTypes = [] }
                case .eu:
                    tokenTypes = ["ACQUISITION", "SERVICES"]
                case .none:
                    tokenTypes = []
                }
                for type in tokenTypes {
                    if let token = try await ExternalPurchaseCustomLink.token(for: type) {
                        ZSLogger.info("[ExternalPurchase] minted \(type) token", category: .checkout)
                        return token.value
                    }
                }
            } catch {
                ZSLogger.info("[ExternalPurchase] custom-link mint failed: \(error)", category: .checkout)
                // fall through to notice-sheet path
            }
        }

        // Older alternative-payment path, EEA only in v1. Floor is iOS 17.4
        // (not 15.4): both `ExternalPurchase.canPresent` and the token-bearing
        // `.continuedWithExternalPurchaseToken` case are iOS 17.4+ in the SDK
        // headers — below that the notice sheet can't deliver a token in-app.
        if region == .eu, #available(iOS 17.4, *) {
            do {
                guard await ExternalPurchase.canPresent else { return nil }
                let result = try await ExternalPurchase.presentNoticeSheet()
                switch result {
                case .continuedWithExternalPurchaseToken(let token):
                    ZSLogger.info("[ExternalPurchase] notice-sheet token minted", category: .checkout)
                    return token
                case .cancelled:
                    ZSLogger.info("[ExternalPurchase] notice sheet cancelled by user", category: .checkout)
                    return nil
                @unknown default:
                    return nil
                }
            } catch {
                ZSLogger.info("[ExternalPurchase] notice sheet failed: \(error)", category: .checkout)
                return nil
            }
        }
        #endif
        return nil
    }
}
