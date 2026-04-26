//
//  ZSDemoMode.swift
//  ZeroSettleKit
//
//  Debug-only flag controlling which configured offer the SDK previews.
//  Shared by ``ZSOfferManager`` and the deprecated ``ZSMigrationManager``.
//

import Foundation

/// Selects which configured offer the SDK previews in debug builds.
///
/// Enabling demo mode bypasses client-side eligibility gates (rollout,
/// "already on web", min/max subscription tenure, etc.) AND tells the
/// backend to surface the corresponding dashboard-configured campaign
/// regardless of the user's real subscription state. Lets developers
/// preview their tip UI without crafting a specific test account.
///
/// - Important: Gate assignments behind `#if DEBUG`. The backend honors
///   the demo signal only on test-mode publishable keys (`zs_pk_test_*`),
///   so a Release build with demo mode somehow set still receives the
///   real, user-state-resolved response — but the SDK's own gates would
///   still be bypassed locally, which is incorrect for production.
///
/// ## Usage
///
/// ```swift
/// #if DEBUG
/// ZSOfferManager.demoMode = .migration   // preview Switch & Save
/// ZSOfferManager.demoMode = .upgrade     // preview Upgrade & Save
/// ZSOfferManager.demoMode = .off         // production behavior
/// #endif
/// ```
public enum ZSDemoMode: String, Sendable, CaseIterable {
    /// Demo mode is off. Production-equivalent behavior.
    case off

    /// Preview the configured ``MigrationCampaign`` (Switch & Save).
    /// Backend receives `?demo=migration` and skips user-state filtering;
    /// SDK bypasses migration-specific gates.
    case migration

    /// Preview the configured `UpgradeOfferConfig` (Upgrade & Save).
    /// Backend receives `?demo=upgrade` and surfaces the first configured
    /// upgrade path; SDK bypasses upgrade-specific gates.
    case upgrade

    /// Whether any preview flow is active.
    public var isActive: Bool { self != .off }
}
