//
//  AccessStore.swift
//  ZeroSettleKit
//
//  On-device cache of the last present ZSAccess, one entry per user and
//  environment, so plan and feature checks work on a cold, offline launch.
//

import CryptoKit
import Foundation

enum AccessStore {

    /// `zs.access.v1.<sandbox|live>.<first 16 hex of SHA-256 of the user id>`.
    /// Hashing keeps the raw user id out of the defaults plist.
    static func key(userId: String, sandbox: Bool) -> String {
        let digest = SHA256.hash(data: Data(userId.utf8))
        let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "zs.access.v1.\(sandbox ? "sandbox" : "live").\(prefix)"
    }

    static func load(userId: String, sandbox: Bool, defaults: UserDefaults = .standard) -> ZSAccess? {
        guard let data = defaults.data(forKey: key(userId: userId, sandbox: sandbox)),
              let access = try? JSONDecoder().decode(ZSAccess.self, from: data),
              access.isPresent
        else { return nil }
        return access
    }

    static func save(_ access: ZSAccess, userId: String, sandbox: Bool, defaults: UserDefaults = .standard) {
        guard access.isPresent, let data = try? JSONEncoder().encode(access) else { return }
        defaults.set(data, forKey: key(userId: userId, sandbox: sandbox))
    }

    static func remove(userId: String, sandbox: Bool, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(userId: userId, sandbox: sandbox))
    }
}
