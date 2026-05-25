//
//  Configuration.swift
//  ZeroSettleKit
//
//  Public SDK-level configuration constants. Add new constants here as
//  they're needed; do NOT mutate existing ones across releases without
//  a major version bump (downstream wrappers may pin against them).
//

import Foundation

/// Public configuration namespace for ZeroSettleKit.
public enum Configuration {
    /// The semver version of this SDK build. Sent as the `X-ZS-SDK-Version`
    /// header on every Backend API call so the backend can route requests
    /// based on installed SDK capabilities (deferred-mode pivot).
    ///
    /// > Note: Consuming apps do not need to read or pass this — the SDK
    /// > applies it internally on every backend call. Exposed publicly
    /// > only for diagnostic logging.
    ///
    /// Bump this in lockstep with `ZeroSettleKit.podspec` `s.version` and
    /// the wrapper podspecs (Flutter, React Native). The backend uses this
    /// to gate the deferred-mode pivot — see
    /// `backend/api/services/sdk_version.py:MIN_DEFERRED_VERSION`.
    public static let sdkVersion: String = "1.4.1"
}
