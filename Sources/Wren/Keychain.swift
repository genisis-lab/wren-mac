import Foundation
import Security

/// The app password lives in the login keychain, never in preferences; so does a PGP key (`kind` "PGP"), still
/// protected by its passphrase.
enum Keychain {
    private static func query(_ username: String, _ server: URL, _ kind: String) -> [String: Any] {
        let service = kind.isEmpty ? "Wren \(server.absoluteString)" : "Wren \(kind) \(server.absoluteString)"
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: username]
    }

    static func save(_ secret: String, username: String, server: URL, kind: String = "") throws {
        SecItemDelete(query(username, server, kind) as CFDictionary)
        var item = query(username, server, kind)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            let what = kind.isEmpty ? "the app password" : "your \(kind) key"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Couldn’t save \(what) in your keychain."])
        }
    }

    static func read(username: String, server: URL, kind: String = "") -> String? {
        var q = query(username, server, kind)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(username: String, server: URL, kind: String = "") {
        SecItemDelete(query(username, server, kind) as CFDictionary)
    }
}
