import Foundation
import XCTest
@testable import WrenKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WrenKitTests: XCTestCase {
    func testJSONRoundTripsAndKeepsIntegersWhole() throws {
        let value: JSON = ["limit": 50, "ratio": 0.5, "on": true, "none": nil, "list": ["a", 1]]
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertTrue(text.contains("\"limit\":50"), text)
        XCTAssertFalse(text.contains("50.0"), text)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: Data(text.utf8)), value)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: Data("[true, 1]".utf8)), [true, 1])
    }

    func testServerAddressNeedsHTTPSExceptOnThisMac() {
        XCTAssertEqual(ServerAddress.url(from: " mail.example.com ")?.absoluteString, "https://mail.example.com")
        XCTAssertEqual(ServerAddress.url(from: "https://mail.example.com/inbox?x=1")?.absoluteString, "https://mail.example.com")
        XCTAssertEqual(ServerAddress.url(from: "http://localhost:8787")?.absoluteString, "http://localhost:8787")
        XCTAssertNil(ServerAddress.url(from: "http://mail.example.com"))
        XCTAssertNil(ServerAddress.url(from: "ftp://mail.example.com"))
        XCTAssertNil(ServerAddress.url(from: ""))
    }

    func testAddressesParseNamesQuotesAndSeparators() throws {
        let list = try Addresses.parse("Ada <ada@example.com>, bob@example.org; \"Hopper, Grace\" <grace@navy.mil>\n")
        XCTAssertEqual(list, [
            EmailAddress(name: "Ada", email: "ada@example.com"),
            EmailAddress(email: "bob@example.org"),
            EmailAddress(name: "Hopper, Grace", email: "grace@navy.mil"),
        ])
        XCTAssertEqual(try Addresses.parse(" , "), [])
        XCTAssertThrowsError(try Addresses.parse("ada@example.com, not an address")) { error in
            XCTAssertEqual(error as? Addresses.Invalid, Addresses.Invalid(text: "not an address"))
        }
        XCTAssertThrowsError(try Addresses.parse("ada@localhost"))
        XCTAssertEqual(EmailAddress(name: "Hopper, Grace", email: "g@navy.mil").formatted, "\"Hopper, Grace\" <g@navy.mil>")
        XCTAssertEqual(try Addresses.parse(EmailAddress(name: "Hopper, Grace", email: "g@navy.mil").formatted).first?.name, "Hopper, Grace")
    }

    func testTemplatesAreFilledSafely() {
        XCTAssertEqual(
            expand("https://x/jmap/download/{accountId}/{blobId}/{name}?accept={type}", ["accountId": "u1", "blobId": "A7", "name": "Q3 plan/final.pdf", "type": "application/pdf"]),
            "https://x/jmap/download/u1/A7/Q3%20plan%2Ffinal.pdf?accept=application%2Fpdf"
        )
    }

    func testReplyAllSkipsMeAndThreads() {
        let me = Identity(id: "I1", name: "Ada", email: "ada@wren.test", textSignature: "Ada\nWren")
        let email = Email(
            id: "M1", threadId: "T1", mailboxIds: ["inbox": true], keywords: [:],
            from: [EmailAddress(name: "Grace", email: "grace@example.com")],
            to: [EmailAddress(name: "Ada", email: "ADA@wren.test"), EmailAddress(email: "bob@example.com")],
            cc: [EmailAddress(email: "grace@example.com"), EmailAddress(email: "carol@example.com")],
            subject: "Lunch?", receivedAt: Date(timeIntervalSince1970: 0), messageId: ["m1@example.com"], references: ["m0@example.com"],
            textBody: [BodyPart(partId: "t", size: 5, type: "text/plain")], bodyValues: ["t": BodyValue(value: "Noon?\n> earlier")]
        )
        let d = Draft.reply(to: email, all: true, account: "u1", identities: [me])
        XCTAssertEqual(d.to, "Grace <grace@example.com>")
        XCTAssertEqual(d.cc, "bob@example.com, carol@example.com")
        XCTAssertEqual(d.subject, "Re: Lunch?")
        XCTAssertEqual(d.identityId, "I1")
        XCTAssertEqual(d.inReplyTo, ["m1@example.com"])
        XCTAssertEqual(d.references, ["m0@example.com", "m1@example.com"])
        XCTAssertTrue(d.body.hasPrefix("\n\nAda\nWren\n\n"), d.body)
        XCTAssertTrue(d.body.hasSuffix("Grace wrote:\n\n> Noon?\n>> earlier"), d.body)
        // The editor gets the quote as HTML: the original's text, escaped, in a blockquote.
        XCTAssertTrue(d.html?.hasPrefix("<br><br><div class=\"wren-signature\">Ada<br>Wren</div><br><br><div class=\"wren-quote\"><div>") == true, d.html ?? "")
        XCTAssertTrue(d.html?.contains("<pre style=\"white-space:pre-wrap;font-family:inherit\">Noon?\n&gt; earlier</pre></blockquote>") == true, d.html ?? "")
        var rich = email
        rich.htmlBody = [BodyPart(partId: "h", size: 1, type: "text/html")]
        rich.bodyValues?["h"] = BodyValue(value: "<p>Noon?</p><img src=\"https://t.example/open.gif\" width=\"1\" height=\"1\">")
        let quoted = Draft.reply(to: rich, all: false, account: "u1", identities: [me]).html ?? ""
        XCTAssertTrue(quoted.contains("<blockquote type=\"cite\""), quoted)
        XCTAssertTrue(quoted.contains("<p>Noon?</p>"), quoted)
        XCTAssertFalse(quoted.contains("open.gif"), quoted)
        XCTAssertEqual(Draft.reply(to: email, all: false, account: "u1", identities: [me]).cc, "")
        XCTAssertEqual(Draft.prefixed("Re:", "RE: Lunch?"), "RE: Lunch?")

        // Replying to your own sent message goes to its recipients.
        var sent = email
        sent.from = [EmailAddress(email: "ada@wren.test")]
        XCTAssertEqual(Draft.reply(to: sent, all: false, account: "u1", identities: [me]).to, "Ada <ADA@wren.test>, bob@example.com")
    }

    func testReplyGoesToReplyToUnlessItIsEmpty() {
        let me = Identity(id: "I1", name: "Ada", email: "ada@wren.test")
        var email = Email(id: "M1", threadId: "T1", mailboxIds: [:], keywords: [:], from: [EmailAddress(email: "news@example.com")], replyTo: [EmailAddress(email: "help@example.com")])
        XCTAssertEqual(Draft.reply(to: email, all: false, account: "u1", identities: [me]).to, "help@example.com")
        email.replyTo = []
        XCTAssertEqual(Draft.reply(to: email, all: false, account: "u1", identities: [me]).to, "news@example.com")
    }

    func testDraftBecomesAnEmailSetCreate() throws {
        var d = Draft(accountId: "u1", identityId: "I1")
        d.to = "Grace <grace@example.com>"
        d.subject = "Hi"
        d.body = "Hello"
        d.files = [.init(blobId: "A3", name: "a.txt", type: "text/plain", size: 2)]
        let o = try d.emailObject(from: Identity(id: "I1", name: "Ada", email: "ada@wren.test"), draftsMailbox: "drafts")
        XCTAssertEqual(o["mailboxIds"], ["drafts": true])
        XCTAssertEqual(o["from"], [["name": "Ada", "email": "ada@wren.test"]])
        XCTAssertEqual(o["to"], [["name": "Grace", "email": "grace@example.com"]])
        XCTAssertEqual(o["bodyValues"]?["body"]?["value"], "Hello")
        XCTAssertEqual(o["attachments"]?.array?.first?["blobId"], "A3")
        // A draft saves even with an address that's still being typed; sending checks first.
        d.cc = "nope, bob@example.org"
        XCTAssertEqual(try d.emailObject(from: Identity(id: "I1", name: "Ada", email: "ada@wren.test"), draftsMailbox: "drafts")["cc"], [["email": "bob@example.org"]])
        XCTAssertThrowsError(try d.recipients)
        XCTAssertNil(try d.emailObject(from: Identity(id: "I1", name: "Ada", email: "ada@wren.test"), draftsMailbox: "drafts")["htmlBody"])
    }

    func testRichDraftSendsHTMLWithATextAlternative() throws {
        var d = Draft(accountId: "u1", identityId: "I1")
        d.setHTML("<div>Hi <b>Grace</b> &amp; Kim,</div><ul><li>One</li></ul><div><br></div>")
        XCTAssertEqual(d.body, "Hi Grace & Kim,\n• One")
        let o = try d.emailObject(from: Identity(id: "I1", name: "Ada", email: "ada@wren.test"), draftsMailbox: "drafts")
        XCTAssertEqual(o["textBody"], [["partId": "body", "type": "text/plain"]])
        XCTAssertEqual(o["htmlBody"], [["partId": "html", "type": "text/html"]])
        XCTAssertEqual(o["bodyValues"]?["html"]?["value"]?.string, d.html)
        XCTAssertEqual(o["bodyValues"]?["body"]?["value"], "Hi Grace & Kim,\n• One")
        XCTAssertEqual(Draft.html(fromText: "a < b\nc"), "a &lt; b<br>c")
    }

    func testPGPKindIsToldFromTheMessage() {
        let block = "-----BEGIN PGP MESSAGE-----\n\nwcFMA\n-----END PGP MESSAGE-----"
        var email = Email(id: "M1", threadId: "T1", mailboxIds: [:], keywords: [:])
        func text(_ value: String) {
            email.textBody = [BodyPart(partId: "t", size: 1, type: "text/plain")]
            email.bodyValues = ["t": BodyValue(value: value)]
        }
        XCTAssertNil(PGPKind(email))
        // Inline, as some apps indent it: found, and the indent taken off.
        text("Hi,\n  " + block.replacingOccurrences(of: "\n", with: "\n  ") + "\nBye")
        XCTAssertEqual(PGPKind(email), .encrypted)
        XCTAssertEqual(PGPKind.armored(in: email.text), block)
        XCTAssertTrue(PGPKind.isMessage(email.text))
        text("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\nHello\n-----BEGIN PGP SIGNATURE-----\n\nwnUE\n-----END PGP SIGNATURE-----")
        XCTAssertEqual(PGPKind(email), .signed)
        XCTAssertEqual(PGPKind.armored(in: email.text, signed: true), email.text)
        XCTAssertNil(PGPKind.armored(in: email.text))
        // PGP/MIME (RFC 3156): what's encrypted is the part that isn't the version part; a signature is its own part.
        let version = BodyPart(blobId: "A1", size: 10, name: nil, type: "application/pgp-encrypted")
        let data = BodyPart(blobId: "A2", size: 900, name: "encrypted.asc", type: "application/octet-stream")
        email.attachments = [version, data]
        XCTAssertEqual(PGPKind(email), .encryptedMIME)
        XCTAssertEqual(PGPKind.encryptedMIME.part(of: email), data)
        text("Hello")
        let signature = BodyPart(blobId: "A3", size: 300, name: "signature.asc", type: "application/pgp-signature")
        email.attachments = [signature]
        XCTAssertEqual(PGPKind(email), .signedMIME)
        XCTAssertEqual(PGPKind.signedMIME.part(of: email), signature)
        XCTAssertFalse(PGPKind.signedMIME.isEncrypted)
    }

    func testMovesKeepLabelsAndReplaceTheFolder() {
        let email = Email(id: "M1", threadId: "T1", mailboxIds: ["inbox": true, "L1C2": true], keywords: [:])
        let folders: Set<String> = ["inbox", "archive", "trash", "snoozed"]
        XCTAssertEqual(Patch.move(email, to: "archive", folders: folders), ["mailboxIds": ["archive": true, "L1C2": true]])
        XCTAssertEqual(Patch.restore(email), ["mailboxIds": ["inbox": true, "L1C2": true]])
        XCTAssertEqual(Patch.keyword("$seen", false), ["keywords/$seen": nil])
        let snooze = Patch.snooze(email, until: Date(timeIntervalSince1970: 86_400), snoozedMailbox: "snoozed", folders: folders)
        XCTAssertEqual(snooze, ["mailboxIds": ["snoozed": true, "L1C2": true], "snoozed": ["until": "1970-01-02T00:00:00Z"]])
    }

    func testSnoozeTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = { (text: String) in try! Date(text, strategy: .iso8601) }
        // A Tuesday morning: tonight, tomorrow morning, and next Monday.
        XCTAssertEqual(SnoozeTime.choices(now: date("2026-10-27T10:00:00Z"), calendar: calendar).map(\.date), [
            date("2026-10-27T21:00:00Z"), date("2026-10-28T08:00:00Z"), date("2026-11-02T08:00:00Z"),
        ])
        // Late on a Monday: no "tonight", and next week means the Monday after.
        XCTAssertEqual(SnoozeTime.choices(now: date("2026-11-02T22:00:00Z"), calendar: calendar).map(\.date), [
            date("2026-11-03T08:00:00Z"), date("2026-11-09T08:00:00Z"),
        ])
    }

    func testHTMLBecomesReadableText() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hi&nbsp;Ada,</p><p>Line one<br>Line two</p><ul><li>A</li><li>B &amp; C</li></ul></body></html>"
        XCTAssertEqual(plainText(fromHTML: html), "Hi Ada,\nLine one\nLine two\n• A\n• B & C")
    }

    func testQuotesKeepTheirMarksAsText() {
        let html = "<div>Thanks!</div><br><div>On Monday, Ada wrote:</div><blockquote type=\"cite\"><p>Is 3 &lt; 4?</p><p></p>"
            + "<blockquote><div>Yes &amp; no</div></blockquote></blockquote><!-- <blockquote>not this</blockquote> -->"
        XCTAssertEqual(plainText(fromHTML: html), "Thanks!\n\nOn Monday, Ada wrote:\n\n> Is 3 < 4?\n>\n> > Yes & no")
    }

    func testInlineImagesAreNotListedAsFiles() {
        var email = Email(id: "M1", threadId: "T1", mailboxIds: [:], keywords: [:])
        email.htmlBody = [BodyPart(partId: "h", size: 1, type: "text/html")]
        email.bodyValues = ["h": BodyValue(value: "<img src=\"cid:logo@x\">")]
        email.attachments = [
            BodyPart(partId: "a1", blobId: "A1", size: 1, name: "logo.png", type: "image/png", disposition: "inline", cid: "logo@x"),
            BodyPart(partId: "a2", blobId: "A2", size: 1, name: "plan.pdf", type: "application/pdf", disposition: "attachment"),
        ]
        XCTAssertEqual(email.files.map(\.name), ["plan.pdf"])
        XCTAssertEqual(email.text, "")
    }

    func testMethodErrorsAndSetErrorsThrow() throws {
        let body: JSON = ["methodResponses": [["error", ["type": "invalidArguments", "description": "Nope"], "0"]]]
        XCTAssertThrowsError(try Responses(body)) { XCTAssertEqual($0 as? JMAPError, .method("invalidArguments", "Nope")) }
        XCTAssertThrowsError(try checkSet(["notUpdated": ["M1": ["type": "forbidden", "description": "On legal hold"]]])) {
            XCTAssertEqual($0.localizedDescription, "On legal hold")
        }
        XCTAssertNoThrow(try checkSet(["notDestroyed": ["M1": ["type": "notFound"]]], ignoringMissing: true))
    }

    func testConversationsAreOneRequest() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        Mock.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("ada@wren.test:wren_app".utf8).base64EncodedString())
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:], Capability.snooze: [:]],
                    "accounts": [
                        "u2": ["name": "team@wren.test", "isPersonal": false, "accountCapabilities": [Capability.mail: [:]]],
                        "u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:], Capability.snooze: [:]]],
                    ],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            XCTAssertEqual(body["using"], [.string(Capability.core), .string(Capability.mail), .string(Capability.submission), .string(Capability.snooze)])
            let calls = body["methodCalls"]?.array ?? []
            XCTAssertEqual(calls.map { $0.array?[0] }, ["Email/query", "Email/get", "Thread/get", "SearchSnippet/get"])
            XCTAssertEqual(calls[0].array?[1]["filter"], ["inMailbox": "inbox", "text": "lunch"])
            XCTAssertEqual(calls[2].array?[1]["#ids"]?["path"], "/list/*/threadId")
            XCTAssertEqual(calls[3].array?[1]["#emailIds"]?["path"], "/ids")
            return ["methodResponses": [
                ["Email/query", ["ids": ["M1"], "total": 7], "0"],
                ["Email/get", ["list": [[
                    "id": "M1", "threadId": "T1", "mailboxIds": ["inbox": true], "keywords": ["$seen": true],
                    "from": [["name": nil, "email": "grace@example.com"]], "subject": "Lunch", "receivedAt": "2026-10-26T09:30:00Z",
                ]]], "1"],
                ["Thread/get", ["list": [["id": "T1", "emailIds": ["M0", "M1"]]]], "2"],
                ["SearchSnippet/get", ["list": [["emailId": "M1", "subject": "<mark>Lunch</mark>", "preview": nil]]], "3"],
            ]]
        }
        let session = try await client.connect()
        XCTAssertEqual(session.mailAccounts.map(\.id), ["u1", "u2"])
        XCTAssertEqual(session.mailAccounts.map(\.canSnooze), [true, false])
        let page = try await client.conversations(account: "u1", mailbox: "inbox", search: " lunch ", limit: 50)
        XCTAssertEqual(page.total, 7)
        XCTAssertEqual(page.list.first?.count, 2)
        XCTAssertEqual(page.list.first?.email.receivedAt, Date(timeIntervalSince1970: 1_793_007_000))
        XCTAssertEqual(page.list.first?.email.isUnread, false)
        XCTAssertEqual(page.list.first?.snippet, SearchSnippet(subject: "<mark>Lunch</mark>"))
    }

    func testTrackingPicturesAreRemovedAndCounted() {
        let html = """
        <p>Hi</p><img src="https://cdn.example/hero.png" width="560" height="200">
        <img width="1" height="1" src="https://news.example/o.gif?u=1&amp;m=2"><IMG SRC='https://x.list-manage.com/track/open.php?u=1'>
        <img src="https://a.example/p.png" style="display:none"><img src="https://a.example/m.png" style="display: none; width: 300px" alt="hidden gem">
        <img src="cid:logo@x" width="1" height="1"><img src="https://a.example/w.png" style="width:1px" width="600">
        """
        let (clean, removed) = Trackers.strip(html)
        XCTAssertEqual(removed, 4)
        XCTAssertTrue(clean.contains("hero.png"), clean)
        XCTAssertTrue(clean.contains("m.png"), "a hidden picture with a real size stays")
        XCTAssertTrue(clean.contains("cid:logo@x"), "embedded pictures can't report back")
        XCTAssertFalse(clean.contains("o.gif") || clean.contains("list-manage") || clean.contains("p.png") || clean.contains("w.png"), clean)
        XCTAssertEqual(Trackers.strip("<p>No pictures</p>").removed, 0)
    }

    func testLinksLoseTrackingAndRedirects() {
        func clean(_ s: String) -> String { Trackers.clean(URL(string: s)!).absoluteString }
        XCTAssertEqual(clean("https://shop.example/item?id=7&utm_source=news&fbclid=abc"), "https://shop.example/item?id=7")
        XCTAssertEqual(clean("https://www.google.com/url?q=https%3A%2F%2Fsite.example%2Fa%3Fx%3D1%26utm_medium%3Dmail&sa=D"), "https://site.example/a?x=1")
        XCTAssertEqual(clean("https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fsite.example%2F&data=1"), "https://site.example/")
        XCTAssertEqual(clean("https://site.example/unsubscribe?mkt_tok=abc&utm_campaign=x"), "https://site.example/unsubscribe?mkt_tok=abc")
        XCTAssertEqual(clean("https://site.example/a?q=a%20b&gclid=1"), "https://site.example/a?q=a%20b")
        XCTAssertEqual(clean("https://site.example/a?utm_source=x"), "https://site.example/a")
        XCTAssertEqual(clean("https://site.example/a?ok=1"), "https://site.example/a?ok=1")
        XCTAssertEqual(clean("mailto:ada@example.com?subject=utm_x"), "mailto:ada@example.com?subject=utm_x")
    }

    func testForgottenAttachmentsAreNoticed() {
        var d = Draft(accountId: "u1")
        d.setHTML("Here’s the plan, attached.<br><br><div class=\"wren-signature\">Ada</div>")
        XCTAssertTrue(d.forgotAttachment)
        d.files = [Draft.File(blobId: "B1", name: "plan.pdf", type: "application/pdf", size: 1)]
        XCTAssertFalse(d.forgotAttachment)
        // Only what you wrote counts: not the quote you're answering, nor your signature.
        var reply = Draft(accountId: "u1")
        reply.setHTML("Sounds good.<br><br><div class=\"wren-quote\"><div>Grace wrote:</div><blockquote>I attached the slides.</blockquote></div>")
        XCTAssertFalse(reply.forgotAttachment)
        var signed = Draft(accountId: "u1")
        signed.setHTML("Thanks!<br><br><div class=\"wren-signature\">Attachments are scanned</div>")
        XCTAssertFalse(signed.forgotAttachment)
        var plain = Draft(accountId: "u1")
        plain.body = "See the enclosed form.\n\nOn 1 Dec, Grace wrote:\n\n> attached"
        XCTAssertTrue(plain.forgotAttachment)
        plain.body = "Thanks!\n\nOn 1 Dec, Grace wrote:\n\n> attached"
        XCTAssertFalse(plain.forgotAttachment)
        // Words that only start the same don't count.
        plain.body = "I'm attachedness-free"
        XCTAssertFalse(plain.forgotAttachment)
    }

    func testSignaturesKeepTheirFormatting() {
        let rich = Identity(id: "I1", name: "Ada", email: "ada@wren.test", textSignature: "Ada Wren", htmlSignature: "<b>Ada</b> <a href=\"https://wren.test\">Wren</a>")
        let d = Draft.new(account: "u1", identity: rich)
        XCTAssertEqual(d.html, "<br><br><div class=\"wren-signature\"><b>Ada</b> <a href=\"https://wren.test\">Wren</a></div>")
        XCTAssertEqual(d.body, "\n\nAda Wren")
        // No HTML one: the plain one, escaped; none at all: nothing, and no HTML part.
        let plain = Identity(id: "I2", name: "Ada", email: "ada@wren.test", textSignature: "A <b>")
        XCTAssertEqual(Draft.signatureInner(plain), "A &lt;b&gt;")
        XCTAssertNil(Draft.new(account: "u1", identity: Identity(id: "I3", name: "", email: "x@wren.test")).html)
        XCTAssertEqual(Draft.signatureInner(Identity(id: "I4", name: "", email: "x@wren.test", textSignature: "", htmlSignature: "<p><br></p>")), "")
    }

    func testMailtoLinksBecomeDrafts() {
        let me = Identity(id: "I1", name: "Ada", email: "ada@wren.test", textSignature: "Ada")
        let d = Draft.mailto(URL(string: "mailto:grace@example.com,bob@example.com?cc=carol@example.com&subject=Lunch%20on%20Friday%3F&body=Hi%20Grace%2C%0D%0ANoon%3F&attach=/etc/passwd&to=dan@example.com")!, account: "u1", identity: me)
        XCTAssertEqual(d.to, "grace@example.com, bob@example.com, dan@example.com")
        XCTAssertEqual(d.cc, "carol@example.com")
        XCTAssertEqual(d.subject, "Lunch on Friday?")
        XCTAssertEqual(d.body, "Hi Grace,\nNoon?\n\nAda")
        XCTAssertEqual(d.html, "Hi Grace,<br>Noon?<br><br><div class=\"wren-signature\">Ada</div>")
        XCTAssertTrue(d.files.isEmpty)
        XCTAssertEqual(Draft.mailto(URL(string: "MAILTO:?subject=Hi")!, account: "u1", identity: nil).to, "")
    }

    func testAddressSuggestionsCompleteTheLastAddress() {
        XCTAssertEqual(Addresses.typing("Ada <ada@example.com>, gr"), "gr")
        XCTAssertEqual(Addresses.typing("\"Hopper, Gr"), "\"Hopper, Gr")
        let grace = EmailAddress(name: "Grace Hopper", email: "grace@example.com")
        XCTAssertEqual(Addresses.complete("Ada <ada@example.com>; gr", with: grace), "Ada <ada@example.com>, Grace Hopper <grace@example.com>, ")
        XCTAssertEqual(Addresses.complete("", with: grace), "Grace Hopper <grace@example.com>, ")
        XCTAssertEqual(try Addresses.parse(Addresses.complete("gr", with: grace)), [grace])
    }

    func testSearchSnippetsSplitIntoMatches() {
        let pieces = SearchSnippet.pieces("…lunch on <mark>Friday</mark> &amp; <mark>fish</mark>")
        XCTAssertEqual(pieces.map(\.text), ["…lunch on ", "Friday", " & ", "fish"])
        XCTAssertEqual(pieces.map(\.isMatch), [false, true, false, true])
        XCTAssertEqual(SearchSnippet.pieces("a &lt;b&gt;\n\nc").map(\.text), ["a <b> c"])
    }

    func testVacationPatchSendsOnlyChanges() {
        var old = VacationResponse()
        old.subject = "Away"
        var new = old
        new.isEnabled = true
        new.toDate = Date(timeIntervalSince1970: 86_400)
        XCTAssertEqual(new.patch(from: old), ["isEnabled": true, "toDate": "1970-01-02T00:00:00Z"])
        new.textBody = "Back Monday."
        new.toDate = nil
        old.toDate = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(new.patch(from: old), ["isEnabled": true, "toDate": nil, "textBody": "Back Monday.", "htmlBody": nil])
        XCTAssertEqual(old.patch(from: old), [:])
    }

    func testSettingsAndSuggestionsCalls() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        Mock.handler = { request in
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:], Capability.quota: [:], Capability.vacation: [:], Capability.contacts: [:]],
                    "accounts": ["u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:], Capability.contacts: [:]]]],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            XCTAssertEqual(body["using"], [.string(Capability.core), .string(Capability.mail), .string(Capability.submission), .string(Capability.quota), .string(Capability.vacation), .string(Capability.contacts)])
            let calls = body["methodCalls"]?.array ?? []
            switch calls.first?.array?[0].string {
            case "Quota/get":
                return ["methodResponses": [["Quota/get", ["list": [["id": "mail", "resourceType": "octets", "used": 900, "hardLimit": 1000]]], "0"]]]
            case "VacationResponse/get":
                return ["methodResponses": [["VacationResponse/get", ["list": [["id": "singleton", "isEnabled": true, "fromDate": nil, "toDate": "2026-11-20T00:00:00Z", "subject": "Away", "textBody": "Back soon", "htmlBody": "<p>Back soon</p>"]]], "0"]]]
            case "VacationResponse/set":
                XCTAssertEqual(calls[0].array?[1]["update"], ["singleton": ["isEnabled": false]])
                return ["methodResponses": [["VacationResponse/set", ["updated": ["singleton": nil]], "0"]]]
            default:
                XCTAssertEqual(calls.map { $0.array?[0] }, ["ContactCard/query", "ContactCard/get"])
                XCTAssertEqual(calls[0].array?[1]["filter"], ["text": "gr"])
                return ["methodResponses": [
                    ["ContactCard/query", ["ids": ["K2C1", "K1C1"]], "0"],
                    ["ContactCard/get", ["list": [
                        ["id": "K1C1", "name": nil, "emails": ["e1": ["@type": "EmailAddress", "address": "greg@example.com"]]],
                        ["id": "K2C1", "name": ["full": "Grace Hopper"], "emails": ["e1": ["address": "grace@example.com"], "e2": ["address": "g@navy.mil"]]],
                    ]], "1"],
                ]]
            }
        }
        let quota = try await client.quota(account: "u1")
        XCTAssertEqual(quota?.fraction, 0.9)
        let reply = try await client.vacation(account: "u1")
        XCTAssertEqual(reply.toDate, Date(timeIntervalSince1970: 1_795_132_800))
        XCTAssertEqual(reply.textBody, "Back soon")
        var off = reply
        off.isEnabled = false
        try await client.setVacation(off, was: reply, account: "u1")
        let found = try await client.contacts(matching: "gr", account: "u1")
        XCTAssertEqual(found, [
            EmailAddress(name: "Grace Hopper", email: "grace@example.com"), EmailAddress(name: "Grace Hopper", email: "g@navy.mil"), EmailAddress(email: "greg@example.com"),
        ])
    }

    func testOnlyWhatChangedIsFetched() async throws {
        XCTAssertEqual(
            JMAPClient.changedStates(#"{"@type":"StateChange","changed":{"u1":{"Email":"7","Mailbox":"7"},"s9":{"Mailbox":"3"}}}"#),
            ["u1": "7", "s9": "3"]
        )
        XCTAssertEqual(JMAPClient.changedStates("not json"), [:])
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        Mock.handler = { request in
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:]],
                    "accounts": ["u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:]]]],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            let call = body["methodCalls"]?.array?.first?.array ?? []
            let args = call[1]
            if call[0] == "Email/get" {
                XCTAssertEqual(args["ids"], ["M2"])
                return ["methodResponses": [["Email/get", ["list": [["id": "M2", "threadId": "T2", "mailboxIds": ["inbox": true], "keywords": ["$seen": true]]]], "0"]]]
            }
            // Two pages: M1 made then changed, M3 changed then deleted.
            if args["sinceState"] == "5" {
                return ["methodResponses": [["Email/changes", ["oldState": "5", "newState": "6", "hasMoreChanges": true, "created": ["M1"], "updated": ["M2", "M3"], "destroyed": []], "0"]]]
            }
            if args["sinceState"] == "6" {
                return ["methodResponses": [["Email/changes", ["oldState": "6", "newState": "8", "hasMoreChanges": false, "created": [], "updated": ["M1", "M2"], "destroyed": ["M3"]], "0"]]]
            }
            return ["methodResponses": [["error", ["type": "cannotCalculateChanges"], "0"]]]
        }
        let changes = try await client.emailChanges(account: "u1", since: "5")
        XCTAssertEqual(changes, EmailChanges(created: ["M1"], updated: ["M2"], destroyed: ["M3"], newState: "8"))
        do {
            _ = try await client.emailChanges(account: "u1", since: "1")
            XCTFail("An old state can't be followed")
        } catch JMAPError.method(let type, _) {
            XCTAssertEqual(type, "cannotCalculateChanges")
        }
        let emails = try await client.emails(["M2"], account: "u1")
        XCTAssertEqual(emails.first?.isUnread, false)
        let none = try await client.emails([], account: "u1")
        XCTAssertTrue(none.isEmpty)
    }

    func testLabelsAreMadeRenamedAndDeleted() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        nonisolated(unsafe) var seen: [JSON] = []
        Mock.handler = { request in
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:]],
                    "accounts": ["u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:]]]],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            let args = body["methodCalls"]?.array?.first?.array?[1] ?? nil
            seen.append(args)
            if args["create"] != nil { return ["methodResponses": [["Mailbox/set", ["created": ["label": ["id": "L7"]]], "0"]]] }
            if args["update"] != nil { return ["methodResponses": [["Mailbox/set", ["notUpdated": ["L7": ["type": "alreadyExists", "description": "A mailbox with that name exists"]]], "0"]]] }
            return ["methodResponses": [["Mailbox/set", ["destroyed": ["L7"]], "0"]]]
        }
        let id = try await client.createLabel("Travel", account: "u1")
        XCTAssertEqual(id, "L7")
        do {
            try await client.renameLabel("L7", to: "Work", account: "u1")
            XCTFail("A taken name is refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "A mailbox with that name exists")
        }
        try await client.deleteLabel("L7", account: "u1")
        XCTAssertEqual(seen.map { $0["create"]?["label"]?["name"] }, ["Travel", nil, nil])
        XCTAssertEqual(seen.last?["onDestroyRemoveEmails"], true)
        XCTAssertEqual(seen.last?["destroy"], ["L7"])
    }

    func testHeldSendsCanBeListedAndStopped() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        Mock.handler = { request in
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:]],
                    "accounts": ["u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:]]]],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            let calls = body["methodCalls"]?.array ?? []
            let first = calls.first?.array ?? []
            switch first.first?.string {
            case "EmailSubmission/query":
                XCTAssertEqual(first[1]["filter"], ["undoStatus": "pending"])
                return ["methodResponses": [
                    ["EmailSubmission/query", ["ids": ["S2", "S1"]], "0"],
                    ["EmailSubmission/get", ["list": [
                        ["id": "S2", "emailId": "M2", "threadId": "T2", "sendAt": "2026-12-02T09:00:00Z", "undoStatus": "pending"],
                        ["id": "S1", "emailId": "M1", "threadId": "T1", "sendAt": "2026-12-01T09:00:00.000Z", "undoStatus": "pending"],
                    ]], "1"],
                    ["Email/get", ["list": [["id": "M1", "subject": "Plans", "to": [["name": "Grace", "email": "grace@example.com"]], "cc": nil, "bcc": []]]], "2"],
                ]]
            case "EmailSubmission/set" where first[1]["update"] != nil:
                XCTAssertEqual(first[1]["update"], ["S1": ["undoStatus": "canceled"]])
                return ["methodResponses": [
                    ["EmailSubmission/set", ["updated": ["S1": nil]], "0"],
                    ["EmailSubmission/get", ["list": [["id": "S1", "emailId": "M9"]]], "1"],
                ]]
            default:
                // Held for undo: HOLDUNTIL in the envelope; the server says it's pending.
                XCTAssertNotNil(first[1]["create"]?["send"]?["envelope"]?["mailFrom"]?["parameters"]?["HOLDUNTIL"])
                return ["methodResponses": [["EmailSubmission/set", ["created": ["send": ["id": "S3", "undoStatus": "pending", "sendAt": "2026-12-01T09:00:10Z"]]], "0"]]]
            }
        }
        let me = Identity(id: "I1", name: "Ada", email: "ada@wren.test")
        let sent = try await client.submit(emailId: "M3", account: "u1", identity: me, recipients: [EmailAddress(email: "grace@example.com")], sendAt: .now + 10, draftsMailbox: "d", sentMailbox: "s")
        XCTAssertEqual(sent.id, "S3")
        XCTAssertTrue(sent.isPending)
        XCTAssertEqual(sent.sendAt, parseUTCDate("2026-12-01T09:00:10Z"))
        let list = try await client.pendingSubmissions(account: "u1")
        XCTAssertEqual(list.map(\.id), ["S1", "S2"])
        XCTAssertEqual(list.first?.subject, "Plans")
        XCTAssertEqual(list.first?.to.map(\.email), ["grace@example.com"])
        XCTAssertEqual(list.first?.threadId, "T1")
        let back = try await client.cancel(submission: "S1", account: "u1")
        XCTAssertEqual(back, "M9")
    }

    func testWrenExtensionCalls() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        Mock.handler = { request in
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:], Capability.wren: [:]],
                    "accounts": ["u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:], Capability.wren: [:]]]],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            XCTAssertEqual(body["using"], [.string(Capability.core), .string(Capability.mail), .string(Capability.submission), .string(Capability.wren)])
            let calls = body["methodCalls"]?.array ?? []
            let args = calls.last?.array?[1] ?? nil
            switch calls.first?.array?[0].string {
            case "Thread/get":
                XCTAssertTrue(args["properties"]?.array?.contains("invite") == true)
                return ["methodResponses": [
                    ["Thread/get", ["list": [["id": "T1", "emailIds": ["M1"]]]], "0"],
                    ["Email/get", ["list": [[
                        "id": "M1", "threadId": "T1", "mailboxIds": ["inbox": true], "keywords": [:], "blobId": "R1",
                        "invite": [
                            "method": "REQUEST", "summary": "Planning", "location": "", "start": "2026-12-16T17:00:00Z", "end": "2026-12-16T17:30:00Z",
                            "allDay": false, "status": "CONFIRMED", "organizer": ["email": "maya@example.com", "name": "Maya Chen"],
                            "attendees": [["email": "ada@wren.test", "name": nil, "status": "NEEDS-ACTION"]],
                            "me": ["email": "ada@wren.test", "status": "NEEDS-ACTION"], "rsvp": nil, "canReply": true, "uid": "x", "recurring": false,
                        ],
                    ]]], "1"],
                ]]
            case "Invite/reply":
                XCTAssertEqual(args, ["accountId": "u1", "emailId": "M1", "status": "tentative", "comment": "Running late"])
                return ["methodResponses": [["Invite/reply", ["accountId": "u1", "emailId": "M1", "status": "tentative", "to": "maya@example.com"], "0"]]]
            case "PgpKey/lookup":
                XCTAssertEqual(args["addresses"], ["grace@example.com", "kim@example.com"])
                return ["methodResponses": [["PgpKey/lookup", ["keys": ["grace@example.com": [["fingerprint": "F1", "armored": "KEY"]]]], "0"]]]
            case "PgpBackup/get":
                return ["methodResponses": [["PgpBackup/get", ["list": [["id": "singleton", "fingerprint": "F2", "armored": "LOCKED", "updatedAt": "2026-11-01T00:00:00Z"]]], "0"]]]
            default:
                XCTAssertEqual(args["create"]?["send"]?["privateLinkDays"], 7)
                return ["methodResponses": [["EmailSubmission/set", ["created": ["send": ["id": "S1"]]], "0"]]]
            }
        }
        let invite = try await client.conversation(account: "u1", threadId: "T1").first?.invite
        XCTAssertEqual(invite?.summary, "Planning")
        XCTAssertEqual(invite?.organizer?.name, "Maya Chen")
        XCTAssertEqual(invite?.answer, nil)
        XCTAssertEqual(invite?.canReply, true)
        XCTAssertNotNil(invite?.when())
        XCTAssertEqual(Invite.Answer(status: "DECLINED"), .declined)
        let to = try await client.answer(invite: "M1", .tentative, comment: " Running late ", account: "u1")
        XCTAssertEqual(to, "maya@example.com")
        let keys = try await client.pgpKeys(for: ["Kim@example.com", "grace@example.com", "kim@example.com"], account: "u1")
        XCTAssertEqual(keys, ["grace@example.com": ["KEY"]])
        let backup = try await client.pgpBackup(account: "u1")
        XCTAssertEqual(backup?.armored, "LOCKED")
        let me = Identity(id: "I1", name: "Ada", email: "ada@wren.test")
        try await client.submit(emailId: "M2", account: "u1", identity: me, recipients: [], privateLinkDays: 7, draftsMailbox: "drafts", sentMailbox: "sent")
    }

    func testUnreadFilterBulkChangesAndUnsubscribe() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        nonisolated(unsafe) var unread = (1...501).map { "M\($0)" }
        nonisolated(unsafe) var sets: [JSON] = []
        Mock.handler = { request in
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:], Capability.wren: [:]],
                    "accounts": [
                        "u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:], Capability.wren: ["canSend": true, "unsubscribe": true]]],
                        "u2": ["name": "team@wren.test", "isPersonal": false, "accountCapabilities": [Capability.mail: [:], Capability.wren: ["canSend": false, "unsubscribe": true]]],
                        "u3": ["name": "old@wren.test", "isPersonal": false, "accountCapabilities": [Capability.mail: [:], Capability.wren: [:]]],
                    ],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            let calls = body["methodCalls"]?.array ?? []
            let args = calls.last?.array?[1] ?? nil
            switch calls.first?.array?[0].string {
            case "Email/query" where calls.count > 1:
                XCTAssertEqual(calls[0].array?[1]["filter"], ["inMailbox": "inbox", "notKeyword": "$seen"])
                return ["methodResponses": [["Email/query", ["ids": [], "total": 0], "0"], ["Email/get", ["list": []], "1"], ["Thread/get", ["list": []], "2"]]]
            case "Email/query":
                XCTAssertEqual(args["limit"], 500)
                if args["filter"] == ["inMailbox": "trash"] { return ["methodResponses": [["Email/query", ["ids": sets.isEmpty ? ["M9"] : []], "0"]]] }
                XCTAssertEqual(args["filter"], ["inMailbox": "inbox", "notKeyword": "$seen"])
                return ["methodResponses": [["Email/query", ["ids": .array(unread.prefix(500).map(JSON.string))], "0"]]]
            case "Email/set":
                sets.append(args)
                unread.removeFirst(min(500, unread.count, args["update"]?.object?.count ?? 0))
                return ["methodResponses": [["Email/set", [:], "0"]]]
            case "Thread/get":
                // Only a server that says it can unsubscribe is asked for those properties.
                XCTAssertEqual(args["properties"]?.array?.contains("canUnsubscribe"), args["accountId"] == "u1")
                XCTAssertEqual(args["properties"]?.array?.contains("invite"), true)
                return ["methodResponses": [
                    ["Thread/get", ["list": [["id": "T1", "emailIds": ["M1"]]]], "0"],
                    ["Email/get", ["list": [["id": "M1", "threadId": "T1", "mailboxIds": ["inbox": true], "keywords": [:], "canUnsubscribe": true, "unsubscribed": false]]], "1"],
                ]]
            default:
                XCTAssertEqual(calls.first?.array?[0], "MailingList/unsubscribe")
                XCTAssertEqual(args, ["accountId": "u1", "emailId": "M1"])
                return ["methodResponses": [["MailingList/unsubscribe", ["accountId": "u1", "emailId": "M1", "method": "link", "url": "https://site.example/prefs", "sender": "x@site.example"], "0"]]]
            }
        }
        let accounts = try await client.connect().mailAccounts
        XCTAssertEqual(accounts.map(\.canSend), [true, nil, false])
        XCTAssertEqual(accounts.map(\.canUnsubscribe), [true, nil, true])

        _ = try await client.conversations(account: "u1", mailbox: "inbox", unreadOnly: true, limit: 50)
        let marked = try await client.markAllRead(account: "u1", mailbox: "inbox")
        XCTAssertEqual(marked, 501)
        XCTAssertEqual(sets.map { $0["update"]?.object?.count }, [500, 1])
        XCTAssertEqual(sets[1]["update"]?["M501"], ["keywords/$seen": true])
        sets = []
        let emptied = try await client.empty(account: "u1", mailbox: "trash")
        XCTAssertEqual(emptied, 1)
        XCTAssertEqual(sets, [["accountId": "u1", "destroy": ["M9"]]])

        let email = try await client.conversation(account: "u1", threadId: "T1").first
        XCTAssertEqual(email?.canUnsubscribe, true)
        XCTAssertEqual(email?.unsubscribed, false)
        _ = try await client.conversation(account: "u3", threadId: "T1")
        let done = try await client.unsubscribe(from: "M1", account: "u1")
        XCTAssertEqual(done, Unsubscribed(method: "link", url: URL(string: "https://site.example/prefs"), sender: "x@site.example"))
    }

    func testCacheKeepsListsAndTheNewestConversations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wren-cache-\(UUID().uuidString)")
        let cache = MailCache(folder: folder, keep: 2)
        defer { cache.delete() }
        XCTAssertNil(cache.state)
        let account = Account(id: "u1", name: "ada@wren.test", isPersonal: true, capabilities: [Capability.mail])
        cache.state = .init(accounts: [account], mailboxes: ["u1": [Mailbox(id: "inbox", name: "Inbox", role: "inbox", sortOrder: 1, totalEmails: 3, unreadEmails: 1)]], identities: [:])
        XCTAssertEqual(cache.state?.accounts, [account])
        XCTAssertEqual(cache.state?.mailboxes["u1"]?.first?.unreadEmails, 1)

        let email = Email(id: "M1T1C1", threadId: "T1C1", mailboxIds: ["inbox": true], keywords: [:], subject: "Lunch", receivedAt: Date(timeIntervalSince1970: 1_793_007_000))
        cache.saveList(.init(conversations: [Conversation(email: email, count: 2)], total: 9), account: "u1", mailbox: "L1C2/x")
        XCTAssertEqual(cache.list(account: "u1", mailbox: "L1C2/x")?.conversations.first?.email, email)
        XCTAssertEqual(cache.list(account: "u1", mailbox: "L1C2/x")?.total, 9)
        XCTAssertNil(cache.list(account: "u1", mailbox: "archive"))

        for (i, id) in ["T1", "T2", "T3"].enumerated() {
            cache.saveThread([email], id: id)
            // Distinct times, oldest first.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i) * 100)], ofItemAtPath: folder.appendingPathComponent("threads/\(id).json").path)
        }
        cache.saveThread([email], id: "T4")
        XCTAssertNil(cache.thread("T1"))
        XCTAssertNil(cache.thread("T2"))
        XCTAssertEqual(cache.thread("T3"), [email])
        XCTAssertEqual(cache.thread("T4"), [email])

        cache.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testWrongPasswordReadsWell() async {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "nope", http: Mock.session)
        Mock.handler = { _ in Mock.Reply(status: 401, json: ["detail": "Sign in with your email address and an app password from Wren’s Settings"]) }
        do {
            try await client.connect()
            XCTFail("signed in")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Sign in with your email address and an app password from Wren’s Settings")
        }
    }
}

/// Answers the client's requests in tests.
final class Mock: URLProtocol {
    struct Reply: ExpressibleByDictionaryLiteral {
        var status = 200
        var json: JSON
        /// A body that isn't JSON (a file to download), sent instead of `json`.
        var raw: Data?
        var headers: [String: String] = [:]
        init(status: Int, json: JSON, raw: Data? = nil, headers: [String: String] = [:]) {
            self.status = status
            self.json = json
            self.raw = raw
            self.headers = headers
        }
        init(dictionaryLiteral elements: (String, JSON)...) {
            json = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
        }
    }

    nonisolated(unsafe) static var handler: (URLRequest) throws -> Reply = { _ in [:] }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock.self]
        return URLSession(configuration: config)
    }()

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let reply = try Mock.handler(request)
            let headers = ["Content-Type": reply.raw == nil ? "application/json" : "application/octet-stream"].merging(reply.headers) { $1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try reply.raw ?? JSONEncoder().encode(reply.json))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
