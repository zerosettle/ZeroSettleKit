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
///   Silent — no UI. Raced against a 4s deadline so a hung StoreKit call
///   can't stall checkout.
/// - EEA fallback → `ExternalPurchase.presentNoticeSheet()` whenever the
///   custom-link mint yields no token (iOS < 18.1, custom-link entitlement
///   missing — e.g. the app holds only the alternative-payments entitlement —
///   or the mint failed/returned nothing). Available on iOS 17.4+: both
///   `ExternalPurchase.canPresent` and the token-bearing
///   `.continuedWithExternalPurchaseToken` case require iOS 17.4 per SDK
///   headers — below that the notice sheet can't deliver a token in-app.
///   This path presents UI, so it ONLY runs for user-initiated checkouts
///   (`interactive == true`); preloads/warm-ups never surface a sheet.
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

    /// Deadline for the silent custom-link mint. The notice-sheet path has
    /// no deadline — it legitimately awaits the user.
    static let silentMintDeadline: TimeInterval = 4.0

    enum MintRegion: Equatable {
        case eu        // custom-link ACQUISITION/SERVICES
        case japan     // custom-link LINK_OUT (iOS 26.4+)
        case none      // no token applicable
    }

    /// Ordered mint attempts for a region/interactivity/OS combination.
    enum MintPath: Equatable {
        /// Silent `ExternalPurchaseCustomLink.token(for:)` attempts, in order.
        case customLink(tokenTypes: [String])
        /// `ExternalPurchase.presentNoticeSheet()` — presents UI.
        case noticeSheet
    }

    /// Pure region gate — unit-testable.
    static func region(forStorefront storefront: String?) -> MintRegion {
        guard let code = storefront?.uppercased(), !code.isEmpty else { return .none }
        if code == japanStorefront { return .japan }
        if eeaStorefronts.contains(code) { return .eu }
        return .none
    }

    /// Pure path planner — unit-testable. Encodes the interactive gate: the
    /// notice sheet presents UI, so it is planned ONLY when the checkout is
    /// user-initiated. Preloads/warm-ups (`interactive == false`) get the
    /// silent custom-link path or nothing.
    static func plannedPaths(
        region: MintRegion,
        interactive: Bool,
        customLinkAvailable: Bool,   // iOS 18.1+
        japanLinkOutAvailable: Bool, // iOS 26.4+
        noticeSheetAvailable: Bool   // iOS 17.4+
    ) -> [MintPath] {
        switch region {
        case .none:
            return []
        case .japan:
            // Japan token(for:) types require iOS 26.4+; on older iOS
            // mint nothing (backend gates JP at 26.4 anyway).
            guard customLinkAvailable, japanLinkOutAvailable else { return [] }
            return [.customLink(tokenTypes: ["LINK_OUT"])]
        case .eu:
            var paths: [MintPath] = []
            if customLinkAvailable {
                paths.append(.customLink(tokenTypes: ["ACQUISITION", "SERVICES"]))
            }
            if interactive, noticeSheetAvailable {
                paths.append(.noticeSheet)
            }
            return paths
        }
    }

    /// Mint a token for the current storefront, or nil when not applicable.
    /// Never throws into the checkout path.
    ///
    /// - Parameter interactive: `true` only when the checkout was directly
    ///   user-initiated (buy tap, paywall sheet presentation). Gates the
    ///   notice-sheet fallback — a preload/warm-up must never surface Apple's
    ///   disclosure sheet unprompted.
    static func mintIfNeeded(storefront: String?, interactive: Bool) async -> String? {
        let region = region(forStorefront: storefront)
        guard region != .none else { return nil }

        #if os(iOS)
        let customLinkAvailable: Bool
        if #available(iOS 18.1, *) { customLinkAvailable = true } else { customLinkAvailable = false }
        let japanLinkOutAvailable: Bool
        if #available(iOS 26.4, *) { japanLinkOutAvailable = true } else { japanLinkOutAvailable = false }
        let noticeSheetAvailable: Bool
        if #available(iOS 17.4, *) { noticeSheetAvailable = true } else { noticeSheetAvailable = false }

        let paths = plannedPaths(
            region: region,
            interactive: interactive,
            customLinkAvailable: customLinkAvailable,
            japanLinkOutAvailable: japanLinkOutAvailable,
            noticeSheetAvailable: noticeSheetAvailable
        )

        for path in paths {
            switch path {
            case .customLink(let tokenTypes):
                guard #available(iOS 18.1, *) else { continue }
                do {
                    for type in tokenTypes {
                        let token = try await withDeadline(silentMintDeadline) {
                            try await ExternalPurchaseCustomLink.token(for: type)?.value
                        }
                        if let token {
                            ZSLogger.info("[ExternalPurchase] minted \(type) token", category: .checkout)
                            return token
                        }
                    }
                } catch {
                    ZSLogger.info("[ExternalPurchase] custom-link mint failed: \(error)", category: .checkout)
                    // fall through to the next planned path (notice sheet)
                }

            case .noticeSheet:
                guard #available(iOS 17.4, *) else { continue }
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
        }
        #endif
        return nil
    }

    /// Race `operation` against a deadline. Returns nil when the deadline
    /// expires first; the losing task is cancelled. Consistent with the
    /// provider's degrade-to-nil contract — a hung StoreKit call must not
    /// stall checkout initiation.
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T?
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            // First finisher wins; cancel the loser.
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
