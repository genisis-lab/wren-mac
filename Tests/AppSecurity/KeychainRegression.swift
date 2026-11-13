import Foundation
import Security

// This executable compiles alongside the actual Keychain.swift. These module-local functions replace
// only Security's three write calls, allowing failure tests without touching a user's real Keychain.
private var saved = Data("old".utf8)
private var updateStatus = errSecSuccess
private var addStatus = errSecSuccess
private var adds = 0
private var deletes = 0

func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    if updateStatus == errSecSuccess { saved = (attributes as NSDictionary)[kSecValueData] as! Data }
    return updateStatus
}
func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    adds += 1
    if addStatus == errSecSuccess { saved = (attributes as NSDictionary)[kSecValueData] as! Data }
    return addStatus
}
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    deletes += 1
    saved = Data()
    return errSecSuccess
}

@main struct KeychainRegression {
    static func main() throws {
        let server = URL(string: "https://test.invalid")!
        try Keychain.save("new", username: "test", server: server)
        precondition(saved == Data("new".utf8) && adds == 0 && deletes == 0)
        for kind in ["", "PGP"] {
            saved = Data("keep-me".utf8)
            updateStatus = errSecAuthFailed
            do {
                try Keychain.save("replacement", username: "test", server: server, kind: kind)
                preconditionFailure("A denied update must fail")
            } catch {
                precondition((error as NSError).code == Int(errSecAuthFailed))
                precondition(saved == Data("keep-me".utf8) && adds == 0 && deletes == 0)
            }
        }
        updateStatus = errSecItemNotFound
        try Keychain.save("first-value", username: "test", server: server)
        precondition(saved == Data("first-value".utf8) && adds == 1 && deletes == 0)
        addStatus = errSecDuplicateItem
        do {
            try Keychain.save("lost-race", username: "test", server: server)
            preconditionFailure("A duplicate add must fail without deleting the winner")
        } catch {
            precondition(saved == Data("first-value".utf8) && deletes == 0)
        }
        print("Keychain regression checks passed (existing, denied, first save, duplicate).")
    }
}
