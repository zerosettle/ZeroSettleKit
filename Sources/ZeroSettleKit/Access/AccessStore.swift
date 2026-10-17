//
//  AccessStore.swift
//  ZeroSettleKit
//
//  On-device cache of the last present ZSAccess, one entry per tenant, user and
//  environment, so plan and feature checks work on a cold, offline launch.
//

import CryptoKit
import Foundation

enum AccessStore {

    /// First `count` hex characters of the SHA-256 of `text`.
    private static func shortHash(_ text: String, count: Int) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(count))
    }

    /// First 8 hex characters of the SHA-256 of the publishable key, so two tenants never share an entry.
    static func keyHash(publishableKey: String) -> String {
        shortHash(publishableKey, count: 8)
    }

    /// `zs.access.v1.<sandbox|live>.<8 hex of the key hash>.<16 hex of the user id hash>`.
    /// Hashing keeps the raw user id and key out of the defaults plist.
    static func key(userId: String, sandbox: Bool, keyHash: String) -> String {
        "zs.access.v1.\(sandbox ? "sandbox" : "live").\(keyHash).\(shortHash(userId, count: 16))"
    }

    static func load(userId: String, sandbox: Bool, keyHash: String, defaults: UserDefaults = .standard) -> ZSAccess? {
        guard let data = defaults.data(forKey: key(userId: userId, sandbox: sandbox, keyHash: keyHash)),
              let access = try? JSONDecoder().decode(ZSAccess.self, from: data),
              access.isPresent
        else { return nil }
        return access
    }

    static func save(_ access: ZSAccess, userId: String, sandbox: Bool, keyHash: String, defaults: UserDefaults = .standard) {
        guard access.isPresent, let data = try? JSONEncoder().encode(access) else { return }
        defaults.set(data, forKey: key(userId: userId, sandbox: sandbox, keyHash: keyHash))
    }

    static func remove(userId: String, sandbox: Bool, keyHash: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(userId: userId, sandbox: sandbox, keyHash: keyHash))
    }
}
