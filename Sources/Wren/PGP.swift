import AppKit
import WebKit
import WrenKit

/// PGP as Wren's web app does it, with the same OpenPGP.js (Resources/pgp.js, built from pgp/ in this repository).
/// It runs in a hidden web view that loads nothing from the web, in a script world of its own. Each sign-in's key
/// is kept in the keychain still protected by its passphrase, and unlocked only in memory until Wren quits.
@MainActor @Observable
final class PGP {
    static let shared = PGP()

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// valid: signed by a key Wren knows for the sender. bad: that key, but the message was changed. unknown: a key Wren doesn't know.
    enum Signature: String {
        case valid, bad, unknown
    }

    struct KeyInfo: Equatable {
        var fingerprint: String
        var userIds: [String]
        var publicKey: String

        /// "ABCD 1234 …", the way people compare them.
        var groupedFingerprint: String {
            stride(from: 0, to: fingerprint.count, by: 4).map { i in
                let start = fingerprint.index(fingerprint.startIndex, offsetBy: i)
                return String(fingerprint[start..<(fingerprint.index(start, offsetBy: 4, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex)])
            }.joined(separator: " ")
        }
    }

    /// A decrypted or checked message: what to show, and its signature.
    struct Opened {
        struct File: Hashable {
            var name: String
            var type: String
            var data: Data
        }

        var text: String?
        var html: String?
        var files: [File] = []
        var signature: Signature?
    }

    /// Sign-ins whose key is open for this run of Wren.
    private(set) var unlocked: Set<String> = []
    private var keyGeneration = UUID()
    private var loginGenerations: [String: UUID] = [:]

    private func generation(for login: String) -> [UUID] {
        [keyGeneration] + (loginGenerations[login].map { [$0] } ?? [])
    }

    private func requireCurrent(_ expected: [UUID], login: String) async throws {
        guard !Task.isCancelled, generation(for: login) == expected else {
            // The engine may have started after Lock while its WKWebView was still loading.
            _ = try? await call("lock", [login])
            throw Failure("The PGP key was locked. Unlock it again.")
        }
    }
    /// Each sign-in's key as kept on this Mac (nil: none), read from the keychain once.
    private var keys: [String: KeyInfo?] = [:]
    /// Keys restored while the keychain refused them: kept (still protected) until Wren quits, as the web app does.
    @ObservationIgnored private var kept: [String: String] = [:]

    @ObservationIgnored private var web: WKWebView?
    @ObservationIgnored private var starting: Task<WKWebView, Error>?
    private let world = WKContentWorld.world(name: "pgp")
    private let guardian = Guardian()

    // MARK: Keys

    private func armored(_ login: Login) -> String? {
        Keychain.read(username: login.username, server: login.client.server, kind: "PGP") ?? kept[login.id]
    }

    /// The key kept on this Mac for a sign-in, if any.
    func key(_ login: Login) async -> KeyInfo? {
        if let known = keys[login.id] { return known }
        var info: KeyInfo?
        if let armored = armored(login) { info = try? await describe(call("keyInfo", [armored])) }
        keys[login.id] = info
        return info
    }

    /// The key backed up in Wren on the web, opened with its passphrase and kept in the keychain.
    func restore(_ login: Login, passphrase: String) async throws -> KeyInfo {
        let expected = generation(for: login.id)
        guard let account = login.personal?.id else { throw NotConnected() }
        guard let backup = try await login.client.pgpBackup(account: account) else {
            throw Failure("There’s no key backup in Wren. Back up your key in Wren on the web first: Settings → Encryption.")
        }
        try await requireCurrent(expected, login: login.id)
        let info = try describe(await call("unlock", [login.id, backup.armored, passphrase]))
        try await requireCurrent(expected, login: login.id)
        do {
            try Keychain.save(backup.armored, username: login.username, server: login.client.server, kind: "PGP")
        } catch {
            kept[login.id] = backup.armored
        }
        keys[login.id] = info
        unlocked.insert(login.id)
        return info
    }

    func unlock(_ login: Login, passphrase: String) async throws {
        let expected = generation(for: login.id)
        guard let armored = armored(login) else { throw Failure("There’s no PGP key on this Mac. Restore yours in Settings → Encryption.") }
        _ = try await call("unlock", [login.id, armored, passphrase])
        try await requireCurrent(expected, login: login.id)
        unlocked.insert(login.id)
    }

    /// Ask for the passphrase (again, when it's wrong) and unlock. False when cancelled or there's no key.
    func unlockAsking(_ login: Login) async -> Bool {
        if unlocked.contains(login.id) { return true }
        guard await key(login) != nil else { return false }
        var message = "Enter the passphrase you chose for your key. Wren keeps it unlocked until you quit."
        while let passphrase = Self.askPassphrase(title: "Unlock Your PGP Key", message: message, button: "Unlock") {
            do {
                try await unlock(login, passphrase: passphrase)
                return true
            } catch {
                message = error.localizedDescription + ". Try again."
            }
        }
        return false
    }

    /// A passphrase prompt (nil: cancelled). The passphrase is used once and never kept.
    static func askPassphrase(title: String, message: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Passphrase"
        field.setAccessibilityLabel("Passphrase")
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    /// Close a sign-in's key (every key, without one) until its passphrase is entered again.
    func lock(_ login: Login? = nil) {
        if let login {
            loginGenerations[login.id] = UUID()
            unlocked.remove(login.id)
        } else {
            keyGeneration = UUID()
            loginGenerations.removeAll()
            unlocked = []
        }
        Task { _ = try? await call("lock", [Self.orNull(login?.id)]) }
    }

    /// Take the key off this Mac (the backup in Wren stays).
    func forget(_ login: Login) {
        lock(login)
        Keychain.delete(username: login.username, server: login.client.server, kind: "PGP")
        kept[login.id] = nil
        keys[login.id] = .some(nil)
    }

    // MARK: Messages

    func decrypt(_ armored: String, login: String, senderKeys: [String]) async throws -> Opened {
        let r = try await call("decryptText", [login, armored, senderKeys]) as? [String: Any]
        return Opened(text: r?["text"] as? String, signature: Self.signature(r?["signature"]))
    }

    func decryptMIME(_ data: Data, login: String, senderKeys: [String]) async throws -> Opened {
        try opened(await call("decryptMime", [login, data.base64EncodedString(), senderKeys]))
    }

    func verifyCleartext(_ armored: String, senderKeys: [String]) async throws -> Opened {
        let r = try await call("verifyCleartext", [armored, senderKeys]) as? [String: Any]
        return Opened(text: r?["text"] as? String, signature: Self.signature(r?["signature"]))
    }

    func verifySignedMIME(raw: Data, signature: String, senderKeys: [String]) async throws -> Opened {
        try opened(await call("verifySignedMime", [raw.base64EncodedString(), signature, senderKeys]))
    }

    /// An encrypted attachment (name.pgp): the file, under the name it had.
    func decryptFile(_ data: Data, login: String) async throws -> (data: Data, name: String) {
        let r = try await call("decryptFile", [login, data.base64EncodedString()]) as? [String: Any]
        guard let data = (r?["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw Failure("That file couldn’t be decrypted") }
        return (data, r?["filename"] as? String ?? "")
    }

    // MARK: Sending

    /// The keys that can still be encrypted to (not expired or revoked).
    func usableKeys(_ armored: [String]) async throws -> [String] {
        try await call("usableKeys", [armored]) as? [String] ?? []
    }

    func encrypt(_ text: String, to keys: [String], signingAs login: String?) async throws -> String {
        guard let armored = try await call("encryptText", [Self.orNull(login), text, keys, login != nil]) as? String else { throw Failure("The message couldn’t be encrypted") }
        return armored
    }

    func encryptFile(_ data: Data, name: String, to keys: [String], signingAs login: String?) async throws -> Data {
        let sealed = try await call("encryptFile", [Self.orNull(login), data.base64EncodedString(), name, keys, login != nil]) as? String
        guard let sealed, let data = Data(base64Encoded: sealed) else { throw Failure("\(name) couldn’t be encrypted") }
        return data
    }

    func sign(_ text: String, as login: String) async throws -> String {
        guard let signed = try await call("signText", [login, text]) as? String else { throw Failure("The message couldn’t be signed") }
        return signed
    }

    // MARK: The engine

    private func describe(_ value: Any) throws -> KeyInfo {
        guard let r = value as? [String: Any], let fingerprint = r["fingerprint"] as? String, let publicKey = r["publicKey"] as? String else { throw Failure("That isn’t a PGP key") }
        return KeyInfo(fingerprint: fingerprint, userIds: r["userIds"] as? [String] ?? [], publicKey: publicKey)
    }

    private func opened(_ value: Any) throws -> Opened {
        let r = value as? [String: Any] ?? [:]
        let files = (r["attachments"] as? [[String: Any]] ?? []).compactMap { f -> Opened.File? in
            guard let data = (f["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return Opened.File(name: f["filename"] as? String ?? "Attachment", type: f["contentType"] as? String ?? "application/octet-stream", data: data)
        }
        return Opened(text: r["text"] as? String, html: r["html"] as? String, files: files, signature: Self.signature(r["signature"]))
    }

    private static func orNull(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func signature(_ value: Any?) -> Signature? {
        (value as? String).flatMap(Signature.init(rawValue:))
    }

    /// Call `wren.<name>(…args)` in the engine; it answers { value } or { error }.
    private func call(_ name: String, _ args: [Any]) async throws -> Any {
        let web = try await engine()
        let result: Any = try await withCheckedThrowingContinuation { done in
            web.callAsyncJavaScript("return await wren[name](...args)", arguments: ["name": name, "args": args], in: nil, in: world) { done.resume(with: $0) }
        }
        guard let reply = result as? [String: Any] else { throw Failure("Wren’s PGP engine didn’t answer") }
        if let error = reply["error"] as? String { throw Failure(error) }
        return reply["value"] ?? NSNull()
    }

    /// The hidden web view, started the first time PGP is needed.
    private func engine() async throws -> WKWebView {
        if let web { return web }
        if let starting { return try await starting.value }
        let task = Task { [self] () throws -> WKWebView in
            guard let page = Bundle.main.url(forResource: "pgp", withExtension: "html"),
                  let source = Bundle.main.url(forResource: "pgp", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
            else { throw Failure("Wren’s PGP engine is missing from the app") }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            // The page has no scripts of its own; the engine runs in its own world, where the page can't reach it.
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = guardian
            // A file: page, so the engine has WebCrypto (a secure context).
            view.loadFileURL(page, allowingReadAccessTo: page)
            for _ in 0..<100 {
                let ready: Any? = try? await withCheckedThrowingContinuation { done in
                    view.callAsyncJavaScript("return typeof wren", arguments: [:], in: nil, in: world) { done.resume(with: $0) }
                }
                if ready as? String == "object" { return view }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure("Wren’s PGP engine didn’t start")
        }
        starting = task
        do {
            web = try await task.value
        } catch {
            starting = nil
            throw error
        }
        return web!
    }

    /// Keeps the engine's page where it is: it never goes anywhere else.
    private final class Guardian: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.lastPathComponent == "pgp.html" && navigationAction.request.url?.isFileURL == true ? .allow : .cancel
        }
    }
}

// MARK: Reading and sending

extension MailStore {
    /// The public keys Wren knows for some addresses, by address in lower case.
    func pgpKeys(for addresses: [String], login: Login) async throws -> [String: [String]] {
        guard let personal = login.personal, personal.hasWren else { return [:] }
        return try await login.client.pgpKeys(for: addresses, account: personal.id)
    }

    /// An encrypted or signed message, decrypted or checked against the keys Wren knows for its sender.
    func openPGP(_ email: Email, _ kind: PGPKind, in where: MailboxRef? = nil) async throws -> PGP.Opened {
        guard let place = `where` ?? threadPlace, let login = login(place.login) else { throw NotConnected() }
        let pgp = PGP.shared
        var senderKeys: [String] = []
        if let sender = email.from?.first?.email.lowercased() {
            senderKeys = (try? await pgpKeys(for: [sender], login: login))?[sender] ?? []
        }
        switch kind {
        case .encrypted:
            guard let armored = PGPKind.armored(in: email.text) else { throw PGP.Failure("The encrypted text couldn’t be found") }
            return try await pgp.decrypt(armored, login: login.id, senderKeys: senderKeys)
        case .signed:
            guard let armored = PGPKind.armored(in: email.text, signed: true) else { throw PGP.Failure("The signed text couldn’t be found") }
            return try await pgp.verifyCleartext(armored, senderKeys: senderKeys)
        case .encryptedMIME:
            guard let part = kind.part(of: email) else { throw PGP.Failure("The encrypted part couldn’t be found") }
            return try await pgp.decryptMIME(download(part, in: place), login: login.id, senderKeys: senderKeys)
        case .signedMIME:
            guard let part = kind.part(of: email), let blob = email.blobId else { throw PGP.Failure("The signature couldn’t be found") }
            let raw = try await download(BodyPart(blobId: blob, size: 0, name: "message.eml", type: "message/rfc822"), in: place)
            let signature = String(decoding: try await download(part, in: place), as: UTF8.self)
            return try await pgp.verifySignedMIME(raw: raw, signature: signature, senderKeys: senderKeys)
        }
    }

    /// Who an encrypted draft can't go to: everyone without a usable key Wren knows.
    func missingKeys(_ draft: Draft) async -> [String] {
        guard let login = login(draft.login) ?? logins.first, let recipients = try? draft.recipients.map({ $0.email.lowercased() }), !recipients.isEmpty else { return [] }
        guard let found = try? await pgpKeys(for: recipients, login: login) else { return recipients }
        var missing: [String] = []
        for address in recipients {
            let usable = (try? await PGP.shared.usableKeys(found[address] ?? [])) ?? []
            if usable.isEmpty { missing.append(address) }
        }
        return missing
    }

    /// The draft as it's saved and sent with Encrypt or Sign on: only ever the PGP text, never the plain one.
    /// Encrypted for every recipient and you (so Sent stays readable), with each file as name.pgp; just you, for a draft.
    /// Throws, saying who, when someone has no key; nil when the passphrase prompt was cancelled.
    func sealed(_ draft: Draft, forSending: Bool) async throws -> Draft? {
        let encrypt = draft.encrypt == true
        let sign = draft.sign == true && forSending
        guard encrypt || sign else { return draft }
        guard let login = login(draft.login) ?? logins.first else { throw NotConnected() }
        let pgp = PGP.shared
        guard let own = await pgp.key(login) else { throw PGP.Failure("Restore your PGP key in Settings → Encryption first, or turn off Encrypt and Sign.") }
        if sign, !(await pgp.unlockAsking(login)) { return nil }
        var out = draft
        out.html = nil
        guard encrypt else {
            out.body = try await pgp.sign(draft.body, as: login.id)
            return out
        }
        var keys = [own.publicKey]
        if forSending {
            let recipients = try draft.recipients.map { $0.email.lowercased() }
            let found = try await pgpKeys(for: recipients, login: login)
            for address in recipients {
                let usable = try await pgp.usableKeys(found[address] ?? [])
                if usable.isEmpty {
                    throw PGP.Failure(found[address]?.isEmpty == false
                        ? "The PGP key for \(address) has expired or was revoked. Ask them for a new one, or turn off Encrypt."
                        : "There’s no PGP key for \(address). Remove them or turn off Encrypt.")
                }
                keys += usable
            }
        }
        out.body = try await pgp.encrypt(draft.body, to: keys, signingAs: sign ? login.id : nil)
        // shortcut: files are encrypted when the message is sent, not as they're added (the web app does both); a
        // draft closed with Encrypt on keeps its files as they were uploaded. Encrypt them on upload if that matters.
        if forSending {
            out.files = []
            for file in draft.files {
                let data = try await login.client.download(BodyPart(blobId: file.blobId, size: file.size, name: file.name, type: file.type), account: draft.accountId)
                let sealedFile = try await pgp.encryptFile(data, name: file.name, to: keys, signingAs: sign ? login.id : nil)
                let blob = try await login.client.upload(sealedFile, type: "application/octet-stream", account: draft.accountId)
                out.files.append(Draft.File(blobId: blob.blobId, name: file.name + ".pgp", type: "application/octet-stream", size: blob.size))
            }
        }
        return out
    }
}
