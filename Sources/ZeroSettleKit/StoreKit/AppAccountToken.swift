// AppAccountToken.swift
//
// Deterministic UUIDv5 derivation for StoreKit `appAccountToken`.
//
// Apple requires `appAccountToken` to be a UUID at purchase time. Many
// developers identify users by non-UUID strings (Firebase UIDs, Privy IDs,
// Auth0 sub claims, custom auth tokens). Without a deterministic derivation,
// the JWS appAccountToken cannot be matched to the developer's `userId` for
// cross-account ownership verification — which means cross-account StoreKit
// subscription claims always fail for those developers.
//
// This file defines the canonical derivation. The same algorithm is
// implemented in the ZeroSettle backend at
// `api/services/appaccount_token.py`. Both sides MUST stay in sync.
//
//     ROOT       = uuid5(NAMESPACE_DNS, "appaccounttoken.zerosettle.com")
//     namespace  = uuid5(ROOT, bundle_id)         // tenant-scoped per app
//     derived    = uuid5(namespace, user_id)      // per-user token
//
// If the developer's `userId` already parses as a UUID, the literal value is
// used as-is (no derivation) — preserving compatibility with RevenueCat-style
// integrations that already pass UUIDs through StoreKit.

import CommonCrypto
import Foundation

internal enum AppAccountToken {

    // MARK: - Public

    /// Compute the canonical `appAccountToken` UUID for `(bundleId, userId)`.
    ///
    /// If `userId` already parses as a UUID, returns the same UUID (case
    /// normalised). Otherwise computes
    /// `uuid5(uuid5(ROOT, bundleId), userId)`.
    ///
    /// The bundleId is read from the host app's `Bundle.main.bundleIdentifier`.
    /// Treat empty bundle IDs as a programmer error — purchase code paths
    /// assert non-empty bundle IDs at runtime.
    static func derive(userId: String, bundleId: String) -> UUID {
        precondition(!userId.isEmpty, "userId must be non-empty")
        precondition(!bundleId.isEmpty, "bundleId must be non-empty")

        // UUID-native pass-through: dev provided a UUID directly. Apple's
        // appAccountToken is a UUID, and matching against the user_id sent
        // to the backend works without any derivation.
        if let direct = UUID(uuidString: userId) {
            return direct
        }

        let namespace = uuidv5(namespace: rootNamespace, name: bundleId)
        return uuidv5(namespace: namespace, name: userId)
    }

    // MARK: - Constants

    /// Root namespace: `uuid5(NAMESPACE_DNS, "appaccounttoken.zerosettle.com")`.
    /// Computed once at first access and cached.
    static let rootNamespace: UUID = {
        // RFC 4122 §C: NAMESPACE_DNS = 6ba7b810-9dad-11d1-80b4-00c04fd430c8
        let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        return uuidv5(namespace: dnsNamespace, name: "appaccounttoken.zerosettle.com")
    }()

    // MARK: - UUIDv5 (RFC 4122 §4.3, SHA-1)

    /// Compute a name-based UUID per RFC 4122 §4.3 using SHA-1.
    ///
    /// Steps (RFC §4.3):
    /// 1. SHA-1 hash of (namespace bytes || name UTF-8 bytes).
    /// 2. Take the first 16 bytes.
    /// 3. Set the four most significant bits of byte 6 to `0101` (version 5).
    /// 4. Set the two most significant bits of byte 8 to `10` (RFC 4122 variant).
    static func uuidv5(namespace: UUID, name: String) -> UUID {
        var data = Data()
        withUnsafeBytes(of: namespace.uuid) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(name.utf8))

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }

        // Set version (5) in byte 6.
        digest[6] = (digest[6] & 0x0F) | 0x50
        // Set variant (RFC 4122) in byte 8.
        digest[8] = (digest[8] & 0x3F) | 0x80

        return UUID(uuid: (
            digest[0],  digest[1],  digest[2],  digest[3],
            digest[4],  digest[5],  digest[6],  digest[7],
            digest[8],  digest[9],  digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
