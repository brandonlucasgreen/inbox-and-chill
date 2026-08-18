import Foundation
import Security

/// Minimal Keychain wrapper. All secrets (API keys, tokens) live here,
/// keyed by "<sourceID>.<name>". Nothing sensitive touches UserDefaults,
/// SwiftData, or plain files.
///
/// Items are marked `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: readable
/// only while the Mac is unlocked, and never migrated to another device by
/// iCloud Keychain or a device-to-device transfer — these are personal API
/// tokens with no business leaving this machine. (On the file-based login
/// keychain the attribute is advisory; it becomes enforced if the app ever
/// adopts the data-protection keychain.)
enum Keychain {
    private static let service = "lol.bgreen.inboxandchill"

    /// Read-through cache, keyed the same way as the Keychain itself.
    ///
    /// Connectors ask for their token on *every* operation — every poll
    /// (Linear every 30s), every mark-done, every snooze. Hitting the
    /// Keychain that often is wasteful, and on the file-based login
    /// keychain it is actively hostile: if an item's ACL doesn't name the
    /// running app (say it was created by a build signed with a different
    /// identity), macOS puts up an authorization panel on *every single
    /// read*. Caching turns that into at most one panel per launch.
    ///
    /// The tokens are already resident in memory whenever a request is in
    /// flight, so this widens their exposure to the process lifetime rather
    /// than introducing a new class of risk. All writes go through `set`
    /// and `delete`, so the cache can't drift from the Keychain.
    private static let cache = SecretCache()

    private final class SecretCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func value(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func store(_ value: String, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = value
        }

        func remove(_ key: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.removeValue(forKey: key)
        }

        func removeAll(prefix: String) {
            lock.lock()
            defer { lock.unlock() }
            for key in storage.keys where key.hasPrefix(prefix) {
                storage.removeValue(forKey: key)
            }
        }
    }

    /// Writes always **delete then add**, never `SecItemUpdate`.
    ///
    /// `SecItemUpdate` changes an item's data but keeps its existing access
    /// control list. An item created by a differently-signed build of this
    /// app therefore keeps trusting that dead identity forever, and no
    /// amount of re-entering the credential clears the prompts. Deleting
    /// first guarantees the replacement item's ACL is authored by — and
    /// trusts — whichever build is running now.
    static func set(_ value: String, for key: String) {
        delete(key)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return }
        cache.store(value, for: key)
    }

    static func get(_ key: String) -> String? {
        if let cached = cache.value(for: key) { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        // Only hits are cached: a miss means the user hasn't entered this
        // credential yet, and we want to see it the moment they do.
        cache.store(value, for: key)
        return value
    }

    static func delete(_ key: String) {
        cache.remove(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Deletes every item whose key starts with `prefix`. Used when a source
    /// is removed: "<sourceID>." wipes all of its credentials — including
    /// ones its current descriptor no longer lists (e.g. OAuth tokens after
    /// a switch back to API-key auth) — so deleting a source never strands
    /// secrets in the Keychain.
    static func deleteAll(prefix: String) {
        cache.removeAll(prefix: prefix)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix)
            else { continue }
            delete(account)
        }
    }
}
