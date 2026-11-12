import Foundation

/// The Wren settings an app can show and change, the same as in Settings on the web (Wren's extension,
/// `Preferences/get` and `Preferences/set`): which address new mail is from, the default signature and each
/// address's own, and whether replies and forwards get the signature. Settings that guard the account
/// (forwarding, sign-in alerts) stay on the web.
public struct Preferences: Codable, Hashable, Sendable {
    /// One of your addresses, or "" for your mailbox's own.
    public var defaultFrom = ""
    /// The default signature, as HTML.
    public var signature = ""
    /// Addresses' own signatures (lower-cased address → HTML); an address without one uses the default.
    public var signatures: [String: String] = [:]
    public var signatureOnReplies = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultFrom = try c.decodeIfPresent(String.self, forKey: .defaultFrom) ?? ""
        signature = try c.decodeIfPresent(String.self, forKey: .signature) ?? ""
        signatures = try c.decodeIfPresent([String: String].self, forKey: .signatures) ?? [:]
        signatureOnReplies = try c.decodeIfPresent(Bool.self, forKey: .signatureOnReplies) ?? true
    }

    /// The signature `address` uses: its own, or the default.
    public func signature(for address: String) -> String {
        let own = signatures[address.lowercased()] ?? ""
        return own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? signature : own
    }

    /// Set an address's own signature; empty (or only an empty line from the editor) goes back to the default.
    public mutating func setSignature(_ html: String, for address: String) {
        let key = address.lowercased()
        if Self.isBlank(html) { signatures[key] = nil } else { signatures[key] = html }
    }

    /// What the editor leaves when everything is deleted counts as no signature.
    public static func isBlank(_ html: String) -> Bool {
        let text = plainText(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty && !html.contains("<img")
    }

    /// The Preferences/set patch that turns `old` into this one: only what changed, each address's signature
    /// on its own, so a change made meanwhile on the web to another address isn't undone.
    public func patch(from old: Preferences) -> JSON {
        var p: [String: JSON] = [:]
        if defaultFrom.lowercased() != old.defaultFrom.lowercased() { p["defaultFrom"] = .string(defaultFrom) }
        if signature != old.signature { p["signature"] = .string(Self.isBlank(signature) ? "" : signature) }
        if signatureOnReplies != old.signatureOnReplies { p["signatureOnReplies"] = .bool(signatureOnReplies) }
        for address in Set(signatures.keys).union(old.signatures.keys) where signatures[address] != old.signatures[address] {
            // "/" and "~" are escaped in a patch path (RFC 6901).
            let key = address.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            p["signatures/\(key)"] = signatures[address].map(JSON.string) ?? .null
        }
        return .object(p)
    }
}

extension Identity {
    /// The identity new messages are from: the one chosen in Preferences, else the first (the mailbox's own).
    public static func preferred(_ defaultFrom: String?, among identities: [Identity]) -> Identity? {
        if let from = defaultFrom?.lowercased(), !from.isEmpty, let chosen = identities.first(where: { $0.email.lowercased() == from }) {
            return chosen
        }
        return identities.first
    }
}

extension JMAPClient {
    /// Wren's preferences, for your own account on a server that has them (`Account.hasPreferences`).
    public func preferences(account: String) async throws -> Preferences {
        let r = try await call([("Preferences/get", ["accountId": .string(account), "ids": nil])])
        guard let p = r[0]["list"]?.array?.first else { throw JMAPError.badResponse }
        return try p.decode(Preferences.self)
    }

    public func setPreferences(_ prefs: Preferences, was old: Preferences, account: String) async throws {
        let patch = prefs.patch(from: old)
        guard patch.object?.isEmpty == false else { return }
        let r = try await call([("Preferences/set", ["accountId": .string(account), "update": ["singleton": patch]])])
        try checkSet(r[0])
    }

    /// Change your name (on your mailbox's own identity; aliases are named by an admin).
    public func rename(identity id: String, to name: String, account: String) async throws {
        let r = try await call([("Identity/set", ["accountId": .string(account), "update": [id: ["name": .string(name)]]])])
        try checkSet(r[0])
    }
}
