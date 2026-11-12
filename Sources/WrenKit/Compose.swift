import Foundation

/// A message being written. Codable so a compose window can be restored.
public struct Draft: Codable, Hashable, Sendable, Identifiable {
    public struct File: Codable, Hashable, Sendable {
        public var blobId: String
        public var name: String
        public var type: String
        public var size: Int

        public init(blobId: String, name: String, type: String, size: Int) {
            self.blobId = blobId
            self.name = name
            self.type = type
            self.size = size
        }

        static func list(_ parts: [BodyPart]?) -> [File] {
            (parts ?? []).compactMap { p in p.blobId.map { File(blobId: $0, name: p.name ?? "attachment", type: p.type, size: p.size) } }
        }
    }

    public var id = UUID()
    /// Which of the app's sign-ins the draft belongs to (the app sets it; the engine doesn't use it).
    public var login: String?
    public var accountId: String
    public var identityId: String?
    public var to = ""
    public var cc = ""
    public var bcc = ""
    public var subject = ""
    /// The message as plain text: the whole message, or the alternative to `html`.
    public var body = ""
    /// The message with formatting, when it has any (set it with `setHTML`, which keeps `body` in step).
    public var html: String?
    public var files: [File] = []
    /// Send as a private link that stops working after 1, 7 or 30 days (Wren's extension).
    public var privateLinkDays: Int?
    /// Encrypt or sign with PGP when sent. Optional so drafts kept by older versions still open.
    public var encrypt: Bool?
    public var sign: Bool?
    public var inReplyTo: [String]?
    public var references: [String]?
    /// The saved draft this one was opened from, deleted when it's saved again or sent.
    public var replaces: String?

    public init(accountId: String, identityId: String? = nil) {
        self.accountId = accountId
        self.identityId = identityId
    }

    public var recipients: [EmailAddress] {
        get throws { try Addresses.parse(to) + Addresses.parse(cc) + Addresses.parse(bcc) }
    }

    /// What the editor wrote, with the plain-text alternative made from it.
    public mutating func setHTML(_ html: String) {
        self.html = html
        body = plainText(fromHTML: html)
    }

    /// The Email/set create object for this draft. Addresses that don't parse yet are left out rather than
    /// losing the draft (sending checks `recipients` first).
    public func emailObject(from identity: Identity, draftsMailbox: String) throws -> JSON {
        var o: [String: JSON] = [
            "mailboxIds": [draftsMailbox: true],
            "keywords": ["$draft": true, "$seen": true],
            "from": [try JSON(encoding: identity.address)],
            "to": try JSON(encoding: Addresses.parse(to, skippingInvalid: true)),
            "cc": try JSON(encoding: Addresses.parse(cc, skippingInvalid: true)),
            "bcc": try JSON(encoding: Addresses.parse(bcc, skippingInvalid: true)),
            "subject": .string(subject),
            "textBody": [["partId": "body", "type": "text/plain"]],
            "bodyValues": ["body": ["value": .string(body)]],
            "attachments": .array(files.map { ["blobId": .string($0.blobId), "name": .string($0.name), "type": .string($0.type), "disposition": "attachment"] }),
        ]
        // Text and HTML both, so the server sends multipart/alternative; plain text alone without formatting.
        if let html {
            o["htmlBody"] = [["partId": "html", "type": "text/html"]]
            o["bodyValues"] = ["body": ["value": .string(body)], "html": ["value": .string(html)]]
        }
        if let inReplyTo { o["inReplyTo"] = .array(inReplyTo.map(JSON.string)) }
        if let references { o["references"] = .array(references.map(JSON.string)) }
        return .object(o)
    }

    /// A new message, with the signature below where you type.
    public static func new(account: String, identity: Identity?, to: String = "") -> Draft {
        var d = Draft(accountId: account, identityId: identity?.id)
        d.to = to
        d.body = signatureBlock(identity)
        let signature = signatureHTML(identity)
        if !signature.isEmpty { d.html = signature }
        return d
    }

    /// A new message from a `mailto:` link (RFC 6068): its addresses, subject and body. Anything else a link
    /// asks for (such as attaching files) is ignored.
    public static func mailto(_ url: URL, account: String, identity: Identity?) -> Draft {
        var d = Draft.new(account: account, identity: identity)
        let link = url.absoluteString
        guard link.lowercased().hasPrefix("mailto:") else { return d }
        let parts = link.dropFirst(7).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let decode = { (s: Substring) in (s.removingPercentEncoding ?? String(s)).replacingOccurrences(of: "\r\n", with: "\n") }
        var to = [decode(parts[0])]
        for field in parts.count > 1 ? parts[1].split(separator: "&") : [] {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let value = pair.count > 1 ? decode(pair[1]) : ""
            switch decode(pair[0]).lowercased() {
            case "to": to.append(value)
            case "cc": d.cc = value
            case "bcc": d.bcc = value
            case "subject": d.subject = value
            case "body":
                d.body = value + d.body
                d.html = d.html.map { html(fromText: value) + $0 }
            default: break
            }
        }
        d.to = to.flatMap(Addresses.pieces).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        return d
    }

    /// A reply to `email`, or a reply to everyone on it, from the identity it was sent to.
    public static func reply(to email: Email, all: Bool, account: String, identities: [Identity]) -> Draft {
        let mine = Set(identities.map { $0.email.lowercased() })
        let identity = Identity.best(for: email, among: identities)
        var d = Draft(accountId: account, identityId: identity?.id)
        let fromMe = email.from?.contains { mine.contains($0.email.lowercased()) } ?? false
        // Replying to your own message goes to the people you sent it to.
        // An empty Reply-To is no Reply-To.
        let replyTo = email.replyTo.flatMap { $0.isEmpty ? nil : $0 }
        let primary = fromMe ? (email.to ?? []) : (replyTo ?? email.from ?? [])
        d.to = primary.map(\.formatted).joined(separator: ", ")
        if all {
            var seen = mine.union(primary.map { $0.email.lowercased() })
            let others = ((fromMe ? [] : email.to ?? []) + (email.cc ?? [])).filter { seen.insert($0.email.lowercased()).inserted }
            d.cc = others.map(\.formatted).joined(separator: ", ")
        }
        d.subject = prefixed("Re:", email.subject)
        d.inReplyTo = email.messageId
        d.references = email.messageId.map { (email.references ?? []) + $0 }
        let who = email.from?.first?.displayName ?? "someone"
        let when = email.receivedAt.map { "On \($0.formatted(date: .abbreviated, time: .shortened)), " } ?? ""
        d.body = signatureBlock(identity) + "\n\n\(when)\(who) wrote:\n\n" + quote(email.text)
        d.html = signatureHTML(identity) + quoted(email, intro: "\(when)\(who) wrote:")
        return d
    }

    public static func forward(_ email: Email, account: String, identities: [Identity]) -> Draft {
        let identity = Identity.best(for: email, among: identities)
        var d = Draft(accountId: account, identityId: identity?.id)
        d.subject = prefixed("Fwd:", email.subject)
        var header = ["Begin forwarded message:", ""]
        if let from = email.from, !from.isEmpty { header.append("From: " + from.map(\.formatted).joined(separator: ", ")) }
        header.append("Subject: " + (email.subject ?? ""))
        if let date = email.receivedAt { header.append("Date: " + date.formatted(date: .long, time: .shortened)) }
        if let to = email.to, !to.isEmpty { header.append("To: " + to.map(\.formatted).joined(separator: ", ")) }
        d.body = signatureBlock(identity) + "\n\n" + header.joined(separator: "\n") + "\n\n" + email.text
        d.html = signatureHTML(identity) + html(fromText: "\n\n" + header.joined(separator: "\n")) + quoted(email, intro: nil)
        // Wren copies another message's attachments into the draft, so they're sent along without downloading them.
        d.files = File.list(email.attachments)
        return d
    }

    /// Opening a saved draft to keep writing it.
    public static func editing(_ email: Email, account: String, identities: [Identity]) -> Draft {
        var d = Draft(accountId: account, identityId: Identity.best(for: email, among: identities)?.id)
        d.to = (email.to ?? []).map(\.formatted).joined(separator: ", ")
        d.cc = (email.cc ?? []).map(\.formatted).joined(separator: ", ")
        d.bcc = (email.bcc ?? []).map(\.formatted).joined(separator: ", ")
        d.subject = email.subject ?? ""
        d.body = email.text
        d.html = email.html
        d.files = File.list(email.attachments)
        d.replaces = email.id
        return d
    }

    private static func signatureBlock(_ identity: Identity?) -> String {
        guard let sig = identity?.textSignature?.trimmingCharacters(in: .whitespacesAndNewlines), !sig.isEmpty else { return "" }
        return "\n\n" + sig
    }

    /// The signature for the editor, below where you type: Wren's HTML one (links and formatting kept), or the plain
    /// one. It sits in its own element so choosing another From address can swap it (`signatureInner`).
    public static func signatureHTML(_ identity: Identity?) -> String {
        let inner = signatureInner(identity)
        return inner.isEmpty ? "" : "<br><br><div class=\"wren-signature\">\(inner)</div>"
    }

    /// What goes inside the signature element ("" for none), tracking pictures taken out as from any mail.
    public static func signatureInner(_ identity: Identity?) -> String {
        if let rich = identity?.htmlSignature?.trimmingCharacters(in: .whitespacesAndNewlines), !rich.isEmpty, !plainText(fromHTML: rich).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rich.contains("<img") {
            return Trackers.strip(rich).html
        }
        guard let sig = identity?.textSignature?.trimmingCharacters(in: .whitespacesAndNewlines), !sig.isEmpty else { return "" }
        return html(fromText: sig)
    }

    /// Plain text as editor HTML: escaped, with line breaks kept.
    public static func html(fromText text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    /// The message being answered, in a blockquote as the web app quotes it, trackers taken out.
    static func quoted(_ email: Email, intro: String?) -> String {
        let body = email.html.map { Trackers.strip($0).html } ?? "<pre style=\"white-space:pre-wrap;font-family:inherit\">\(escapeHTML(email.text))</pre>"
        let lead = intro.map { "<div>\(escapeHTML($0))</div>" } ?? ""
        return "<br><br><div class=\"wren-quote\">\(lead)<blockquote type=\"cite\" style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(body)</blockquote></div>"
    }

    static func prefixed(_ prefix: String, _ subject: String?) -> String {
        let s = (subject ?? "").trimmingCharacters(in: .whitespaces)
        return s.lowercased().hasPrefix(prefix.lowercased()) ? s : "\(prefix) \(s)"
    }

    static func quote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(">") ? ">\($0)" : "> \($0)" }.joined(separator: "\n")
    }
}

extension Identity {
    /// The identity a message was sent to, so a reply goes out from the same address; otherwise the first.
    public static func best(for email: Email, among identities: [Identity]) -> Identity? {
        let addressed = Set(((email.to ?? []) + (email.cc ?? []) + (email.from ?? [])).map { $0.email.lowercased() })
        return identities.first { addressed.contains($0.email.lowercased()) } ?? identities.first
    }
}

public enum Addresses {
    public struct Invalid: Error, LocalizedError, Equatable {
        public var text: String
        public var errorDescription: String? { "“\(text)” isn’t an email address." }
    }

    /// The addresses in a To field as typed, split at commas, semicolons and new lines outside quotes and <>.
    static func pieces(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var angled = false
        for ch in text {
            if ch == "\"" { quoted.toggle() }
            else if !quoted && ch == "<" { angled = true }
            else if !quoted && ch == ">" { angled = false }
            else if !quoted && !angled && (ch == "," || ch == ";" || ch == "\n") {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        pieces.append(current)
        return pieces
    }

    /// The address being typed: the last one in the field.
    public static func typing(_ text: String) -> String {
        pieces(text).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The field with the address being typed replaced by a suggestion, ready for the next one.
    public static func complete(_ text: String, with address: EmailAddress) -> String {
        let done = pieces(text).dropLast().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (done + [address.formatted]).joined(separator: ", ") + ", "
    }

    /// Addresses as typed into a To field: `Ada <ada@example.com>, bob@example.com; "Hopper, Grace" <grace@example.com>`.
    public static func parse(_ text: String, skippingInvalid: Bool = false) throws -> [EmailAddress] {
        try pieces(text).compactMap { piece -> EmailAddress? in
            let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { return nil }
            var name: String?
            var email = piece
            if let open = piece.lastIndex(of: "<"), let close = piece.lastIndex(of: ">"), open < close {
                email = String(piece[piece.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                let n = piece[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                name = n.isEmpty ? nil : n
            }
            guard isEmail(email) else {
                if skippingInvalid { return nil }
                throw Invalid(text: piece)
            }
            return EmailAddress(name: name, email: email)
        }
    }

    static func isEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        let bad = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"(),;:[]\\"))
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
            && s.unicodeScalars.allSatisfy { !bad.contains($0) }
    }
}

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// How a message uses PGP, as the web app tells: encrypted or signed, inline in the text or as PGP/MIME (RFC 3156).
public enum PGPKind: Sendable, Equatable {
    case encrypted, encryptedMIME, signed, signedMIME

    private static let message = #"(?m)^[ \t]*-----BEGIN PGP MESSAGE-----[\s\S]*?^[ \t]*-----END PGP MESSAGE-----"#
    private static let clearsigned = #"(?m)^[ \t]*-----BEGIN PGP SIGNED MESSAGE-----[\s\S]*?^[ \t]*-----END PGP SIGNATURE-----"#

    public init?(_ email: Email) {
        let types = Set((email.attachments ?? []).map { $0.type.lowercased() })
        let text = email.text
        if types.contains("application/pgp-encrypted") { self = .encryptedMIME }
        else if Self.isMessage(text) { self = .encrypted }
        else if types.contains("application/pgp-signature") { self = .signedMIME }
        else if text.range(of: Self.clearsigned, options: .regularExpression) != nil { self = .signed }
        else { return nil }
    }

    public var isEncrypted: Bool { self == .encrypted || self == .encryptedMIME }

    /// Whether text holds an encrypted PGP message (an encrypted draft, say).
    public static func isMessage(_ text: String) -> Bool {
        text.range(of: message, options: .regularExpression) != nil
    }

    /// The armored block of an inline message: the encrypted one, or with `signed` the cleartext-signed one.
    public static func armored(in text: String, signed: Bool = false) -> String? {
        text.range(of: signed ? clearsigned : message, options: .regularExpression).map {
            String(text[$0]).replacingOccurrences(of: "(?m)^[ \t]+", with: "", options: .regularExpression)
        }
    }

    /// The part of a PGP/MIME message to read: the encrypted data, or the detached signature.
    public func part(of email: Email) -> BodyPart? {
        let list = email.attachments ?? []
        switch self {
        case .encryptedMIME: return list.first { $0.type.lowercased() != "application/pgp-encrypted" }
        case .signedMIME: return list.first { $0.type.lowercased() == "application/pgp-signature" }
        default: return nil
        }
    }
}

/// HTML as readable plain text, for quoting a reply and for messages without a text part.
public func plainText(fromHTML html: String) -> String {
    var s = html.replacingOccurrences(of: "(?is)<(head|style|script|title)\\b.*?</\\1\\s*>|<!--.*?-->", with: "", options: .regularExpression)
    // Quotes, innermost first, become "> " lines: what an encrypted reply (plain text only) has to show them by.
    // Escaped again, so the steps below leave them as they are. Past 100 deep, quotes lose their marks.
    for _ in 0..<100 {
        guard let quote = s.range(of: "(?is)<blockquote\\b[^>]*>(?:(?!<blockquote\\b).)*?</blockquote\\s*>", options: .regularExpression) else { break }
        let inner = s[quote].replacingOccurrences(of: "(?is)^<blockquote\\b[^>]*>|</blockquote\\s*>$", with: "", options: .regularExpression)
        let lines = plainText(fromHTML: inner).split(separator: "\n", omittingEmptySubsequences: false)
        s.replaceSubrange(quote, with: "<br>" + escapeHTML(lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")) + "<br>")
    }
    for (pattern, replacement) in [
        ("(?i)<br\\s*/?>", "\n"),
        ("(?i)</(p|div|tr|li|h[1-6]|blockquote|table)\\s*>", "\n"),
        ("(?i)<li\\b[^>]*>", "• "),
        ("(?s)<[^>]+>", ""),
    ] {
        s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    for (entity, ch) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
        s = s.replacingOccurrences(of: entity, with: ch)
    }
    s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The times Mail-style menus offer for snoozing and for sending later.
public struct SnoozeTime: Sendable {
    public var title: String
    public var date: Date

    public static func choices(now: Date = .now, calendar: Calendar = .current) -> [SnoozeTime] {
        func at(_ hour: Int, daysAhead: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        var list: [SnoozeTime] = []
        let tonight = at(21, daysAhead: 0)
        if tonight.timeIntervalSince(now) > 30 * 60 { list.append(SnoozeTime(title: "Tonight at \(tonight.formatted(date: .omitted, time: .shortened))", date: tonight)) }
        let tomorrow = at(8, daysAhead: 1)
        list.append(SnoozeTime(title: "Tomorrow at \(tomorrow.formatted(date: .omitted, time: .shortened))", date: tomorrow))
        // The coming Monday morning (a week on, if today is Monday).
        let weekday = calendar.component(.weekday, from: now)
        let untilMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        let monday = at(8, daysAhead: untilMonday)
        list.append(SnoozeTime(title: "Next Week (\(monday.formatted(.dateTime.weekday(.abbreviated).hour().minute())))", date: monday))
        return list
    }
}
