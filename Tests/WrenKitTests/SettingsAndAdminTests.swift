import Foundation
import XCTest
@testable import WrenKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Settings shared with Wren on the web (Preferences, names, signatures) and the admin panel's unlock.
final class SettingsAndAdminTests: XCTestCase {
    func testPreferencesPatchSendsOnlyWhatChanged() {
        var old = Preferences()
        old.defaultFrom = "ada@wren.test"
        old.signature = "<p>Ada</p>"
        old.signatures = ["hello@wren.test": "<p>Hello desk</p>", "a/b~c@wren.test": "<p>Odd</p>"]
        var new = old
        XCTAssertEqual(new.patch(from: old), [:])

        // Another case of the same address isn't a change.
        new.defaultFrom = "ADA@wren.test"
        XCTAssertEqual(new.patch(from: old), [:])

        new.defaultFrom = "Hello@wren.test"
        new.signatureOnReplies = false
        // What the editor leaves when everything's deleted takes the address back to the default.
        new.setSignature("<p><br></p>", for: "Hello@Wren.test")
        new.setSignature("<p>Desk</p>", for: "Desk@wren.test")
        new.setSignature("<p>Still odd</p>", for: "a/b~c@wren.test")
        XCTAssertEqual(new.signatures, ["desk@wren.test": "<p>Desk</p>", "a/b~c@wren.test": "<p>Still odd</p>"])
        XCTAssertEqual(new.patch(from: old), [
            "defaultFrom": "Hello@wren.test",
            "signatureOnReplies": false,
            "signatures/hello@wren.test": nil,
            "signatures/desk@wren.test": "<p>Desk</p>",
            // "~" and "/" are escaped in a patch path.
            "signatures/a~1b~0c@wren.test": "<p>Still odd</p>",
        ])

        // A cleared default signature is sent as none at all.
        new = old
        new.signature = "<div><br></div>"
        XCTAssertEqual(new.patch(from: old), ["signature": ""])
        XCTAssertFalse(Preferences.isBlank("<p><img src=\"data:image/png;base64,AA\"></p>"))
    }

    func testEachAddressUsesItsOwnSignatureOrTheDefault() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"id":"singleton","signature":"<p>Default</p>","signatures":{"hello@wren.test":"<p>Hi</p>","blank@wren.test":"  "}}"#.utf8))
        // What a server leaves out keeps its default.
        XCTAssertEqual(p.defaultFrom, "")
        XCTAssertTrue(p.signatureOnReplies)
        XCTAssertEqual(p.signature(for: "Hello@wren.test"), "<p>Hi</p>")
        XCTAssertEqual(p.signature(for: "blank@wren.test"), "<p>Default</p>")
        XCTAssertEqual(p.signature(for: "ada@wren.test"), "<p>Default</p>")
    }

    func testNewMessagesAreFromTheChosenAddress() {
        let me = Identity(id: "I1", name: "Ada", email: "ada@wren.test")
        let desk = Identity(id: "I2", name: "Hello desk", email: "hello@wren.test")
        XCTAssertEqual(Identity.preferred("HELLO@wren.test", among: [me, desk]), desk)
        XCTAssertEqual(Identity.preferred("", among: [me, desk]), me)
        XCTAssertEqual(Identity.preferred(nil, among: [me, desk]), me)
        // An address that's no longer yours: the mailbox's own.
        XCTAssertEqual(Identity.preferred("gone@wren.test", among: [me, desk]), me)
        XCTAssertNil(Identity.preferred("ada@wren.test", among: []))
    }

    func testRepliesCanLeaveTheSignatureOut() {
        let me = Identity(id: "I1", name: "Ada", email: "ada@wren.test", textSignature: "Ada", htmlSignature: "<b>Ada</b>")
        let email = Email(
            id: "M1", threadId: "T1", mailboxIds: ["inbox": true], keywords: [:],
            from: [EmailAddress(name: "Grace", email: "grace@example.com")], to: [EmailAddress(email: "ada@wren.test")],
            subject: "Lunch?", receivedAt: Date(timeIntervalSince1970: 0),
            textBody: [BodyPart(partId: "t", size: 5, type: "text/plain")], bodyValues: ["t": BodyValue(value: "Noon?")]
        )
        XCTAssertTrue(Draft.reply(to: email, all: false, account: "u1", identities: [me]).html?.contains("wren-signature") == true)
        let reply = Draft.reply(to: email, all: false, account: "u1", identities: [me], signature: false)
        XCTAssertFalse(reply.html?.contains("wren-signature") == true)
        XCTAssertFalse(reply.body.contains("Ada"))
        XCTAssertEqual(reply.identityId, "I1")
        let forward = Draft.forward(email, account: "u1", identities: [me], signature: false)
        XCTAssertFalse(forward.html?.contains("wren-signature") == true)
        XCTAssertTrue(Draft.forward(email, account: "u1", identities: [me]).html?.contains("wren-signature") == true)
    }

    func testTheSessionSaysWhatTheAccountOffers() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        Mock.handler = { _ in
            [
                "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                "capabilities": [Capability.core: [:], Capability.mail: [:], Capability.wren: [:]],
                "accounts": [
                    "u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [
                        Capability.mail: [:], Capability.wren: ["canSend": true, "preferences": true, "adminRole": "helpdesk"],
                    ]],
                    "u2": ["name": "team@wren.test", "isPersonal": false, "accountCapabilities": [Capability.mail: [:], Capability.wren: ["canSend": true]]],
                ],
            ]
        }
        let accounts = try await client.connect().mailAccounts
        XCTAssertEqual(accounts.map(\.hasPreferences), [true, nil])
        XCTAssertEqual(accounts.map(\.adminRole), ["helpdesk", nil])
        // Accounts kept on disk by older versions still open.
        let old = try JSONDecoder().decode(Account.self, from: Data(#"{"id":"u1","name":"ada@wren.test","isPersonal":true,"capabilities":[]}"#.utf8))
        XCTAssertNil(old.adminRole)
    }

    func testSettingsCalls() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        nonisolated(unsafe) var calls: [JSON] = []
        Mock.handler = { request in
            if request.url?.path == "/jmap/session" {
                return [
                    "apiUrl": "https://mail.test/jmap/api", "downloadUrl": "", "uploadUrl": "", "username": "ada@wren.test",
                    "capabilities": [Capability.core: [:], Capability.mail: [:], Capability.wren: [:]],
                    "accounts": ["u1": ["name": "ada@wren.test", "isPersonal": true, "accountCapabilities": [Capability.mail: [:], Capability.wren: ["preferences": true]]]],
                ]
            }
            let body = try JSONDecoder().decode(JSON.self, from: Mock.body(of: request))
            let call = body["methodCalls"]?.array?.first ?? .null
            calls.append(call)
            XCTAssertTrue(body["using"]?.array?.contains(.string(Capability.wren)) == true)
            switch call.array?[0].string {
            case "Preferences/get":
                return ["methodResponses": [["Preferences/get", ["list": [["id": "singleton", "defaultFrom": "", "signature": "<p>A</p>", "signatures": [:], "signatureOnReplies": true]]], "0"]]]
            case "Preferences/set":
                return ["methodResponses": [["Preferences/set", ["updated": ["singleton": nil]], "0"]]]
            default:
                return ["methodResponses": [["Identity/set", ["notUpdated": ["I2": ["type": "forbidden", "description": "An administrator names this address"]]], "0"]]]
            }
        }
        let old = try await client.preferences(account: "u1")
        XCTAssertEqual(old.signature, "<p>A</p>")
        // Nothing changed: nothing sent.
        try await client.setPreferences(old, was: old, account: "u1")
        XCTAssertEqual(calls.count, 1)
        var new = old
        new.signatureOnReplies = false
        try await client.setPreferences(new, was: old, account: "u1")
        XCTAssertEqual(calls.last?.array?[1], ["accountId": "u1", "update": ["singleton": ["signatureOnReplies": false]]])
        do {
            try await client.rename(identity: "I2", to: "Front desk", account: "u1")
            XCTFail("renamed an alias")
        } catch {
            XCTAssertEqual(error.localizedDescription, "An administrator names this address")
        }
        XCTAssertEqual(calls.last?.array?[1], ["accountId": "u1", "update": ["I2": ["name": "Front desk"]]])
    }

    func testUnlockingTakesThePasswordAndASecondStep() async throws {
        let client = JMAPClient(server: URL(string: "https://mail.test")!, username: "ada@wren.test", password: "wren_app", http: Mock.session)
        let admin = AdminClient(client: client)
        nonisolated(unsafe) var seen: [(String, String?, JSON)] = []
        nonisolated(unsafe) var approved = false
        nonisolated(unsafe) var locked = false
        let basic = "Basic " + Data("ada@wren.test:wren_app".utf8).base64EncodedString()
        Mock.handler = { request in
            let body = (try? JSONDecoder().decode(JSON.self, from: Mock.body(of: request))) ?? .null
            seen.append((request.url?.path ?? "", request.value(forHTTPHeaderField: "X-Wren-Admin"), body))
            // Every request also carries the app password: the token alone opens nothing.
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), basic)
            switch request.url?.path {
            case "/jmap/admin/unlock":
                if body["password"] != "right" { return Mock.Reply(status: 401, json: ["error": "Wrong password", "code": nil]) }
                return [
                    "challenge": "CH", "role": "admin", "expiresAt": 1_900_000_000_000,
                    "steps": ["totp": true, "web": true, "email": "a…@example.com"],
                ]
            case "/jmap/admin/unlock/web": return ["number": 42, "url": "https://mail.test/approve"]
            case "/jmap/admin/unlock/email": return ["sentTo": "a…@example.com"]
            case "/jmap/admin/unlock/verify":
                if body["step"] == "web" && !approved { return Mock.Reply(status: 202, json: ["waiting": true]) }
                if body["step"] == "totp" && body["code"] != "123456" { return Mock.Reply(status: 400, json: ["error": "That code isn’t right", "code": "wrong_code"]) }
                let expires = Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000
                return ["token": "TOKEN", "role": "admin", "expiresAt": .number(expires), "idleSeconds": 900]
            case "/jmap/admin/lock":
                return ["ok": true]
            case "/api/admin/users":
                if locked { return Mock.Reply(status: 401, json: ["error": "The admin panel locked", "code": "admin_locked"]) }
                return ["users": [["id": 7, "email": "sam@wren.test", "name": "Sam", "role": "user", "status": "active", "usedBytes": 10, "legalHold": true]]]
            case "/api/admin/domains":
                return Mock.Reply(status: 403, json: ["error": "Use the web", "code": "admin_web_only"])
            default:
                return ["ok": true]
            }
        }

        do {
            _ = try await admin.start(password: "wrong", device: "Wren for Mac")
            XCTFail("unlocked with a wrong password")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Wrong password")
        }
        let challenge = try await admin.start(password: "right", device: "Wren for Mac on Ada’s Mac")
        XCTAssertEqual(challenge.steps, [.totp, .web, .email])
        XCTAssertEqual(challenge.emailTo, "a…@example.com")
        XCTAssertEqual(seen.last?.2, ["password": "right", "device": "Wren for Mac on Ada’s Mac"])
        let isUnlockedAtFirst = await admin.isUnlocked
        XCTAssertFalse(isUnlockedAtFirst)

        // Nothing but the unlock calls works before it's unlocked, and nothing is even sent.
        let before = seen.count
        do {
            let _: [String: [AdminUser]] = try await admin.get("/users")
            XCTFail("used the admin API while locked")
        } catch {
            XCTAssertEqual(error as? AdminError, .locked)
        }
        XCTAssertEqual(seen.count, before)

        let (number, page) = try await admin.askWeb(challenge)
        XCTAssertEqual(number, 42)
        XCTAssertEqual(page?.absoluteString, "https://mail.test/approve")
        let waiting = try await admin.verify(challenge, step: .web)
        XCTAssertFalse(waiting)
        let sentTo = try await admin.sendEmailCode(challenge)
        XCTAssertEqual(sentTo, "a…@example.com")
        do {
            _ = try await admin.verify(challenge, step: .totp, code: "000000")
            XCTFail("unlocked with a wrong code")
        } catch {
            XCTAssertEqual(error as? AdminError, .server(400, "That code isn’t right", code: "wrong_code"))
        }
        approved = true
        let done = try await admin.verify(challenge, step: .web)
        XCTAssertTrue(done)
        XCTAssertEqual(seen.last?.2, ["challenge": "CH", "step": "web"])
        let isUnlocked = await admin.isUnlocked
        XCTAssertTrue(isUnlocked)
        let locksAt = await admin.locksAt
        XCTAssertNotNil(locksAt)
        XCTAssertLessThanOrEqual(locksAt!.timeIntervalSinceNow, 901)

        struct Users: Decodable { var users: [AdminUser] }
        let users = try await admin.get("/users", as: Users.self).users
        XCTAssertEqual(users.first?.email, "sam@wren.test")
        XCTAssertEqual(users.first?.legalHold, true)
        XCTAssertEqual(seen.last?.1, "TOKEN")
        try await admin.send("POST", "/users/7/signout")
        XCTAssertEqual(seen.last?.0, "/api/admin/users/7/signout")
        XCTAssertEqual(seen.last?.2, [:])
        do {
            _ = try await admin.get("/domains", as: JSON.self)
            XCTFail("reached a web-only page")
        } catch {
            XCTAssertEqual(error as? AdminError, .webOnly)
        }

        // The server ended it (app password revoked, an hour passed): locked here too.
        locked = true
        do {
            _ = try await admin.get("/users", as: Users.self)
            XCTFail("still unlocked")
        } catch {
            XCTAssertEqual(error as? AdminError, .locked)
        }
        let stillUnlocked = await admin.isUnlocked
        XCTAssertFalse(stillUnlocked)

        // Locking ends it on the server, once.
        locked = false
        _ = try await admin.verify(challenge, step: .totp, code: "123456")
        await admin.lock()
        XCTAssertEqual(seen.last?.0, "/jmap/admin/lock")
        let count = seen.count
        await admin.lock()
        XCTAssertEqual(seen.count, count)
    }

    func testAdminPagesReadWhatTheServerSends() throws {
        let overview = try JSONDecoder().decode(AdminOverview.self, from: Data(#"""
        {"version":"0.6.0","users":{"total":3,"active":2,"suspended":1,"admins":1},"domains":{"total":1,"verified":null,"enabled":1},
         "queue":{"queued":2,"sending":0,"failed24h":1},"last24":{"received":5,"sent":4,"rejected":null,"spam":1},
         "signIns":{"failed24h":6,"newLocation7d":1,"users":[{"id":7,"email":"sam@wren.test","failed":6,"newLocation":0}]},
         "series":[{"date":1,"received":1,"sent":2,"failed":0}],"warnings":[{"level":"warn","message":"No backups"}]}
        """#.utf8))
        XCTAssertEqual(overview.users, 3)
        XCTAssertEqual(overview.verifiedDomains, 0)
        XCTAssertEqual(overview.rejected24h, 0)
        XCTAssertEqual(overview.flagged.first?.email, "sam@wren.test")
        XCTAssertEqual(overview.warnings.first?.message, "No backups")

        let audit = try JSONDecoder().decode([AdminAuditEntry].self, from: Data(#"""
        [{"id":2,"action":"admin.user_signed_out","target":"sam@wren.test","details":{"via":"app"},"ip":"1.2.3.4","created_at":1000,"user_email":"ada@wren.test","user_id":1},
         {"id":1,"action":"admin.settings","target":null,"details":null,"ip":null,"created_at":900,"user_email":null}]
        """#.utf8))
        XCTAssertEqual(audit.map(\.viaApp), [true, false])

        let invite = try JSONDecoder().decode(AdminInvite.self, from: Data(#"{"id":1,"email":null,"role":"user","expires_at":5,"used_at":null,"created_at":1,"sent_to":"x@example.com","emailed_at":2,"domain":null,"used_by_email":null}"#.utf8))
        XCTAssertEqual(invite.sentTo, "x@example.com")
        let queued = try JSONDecoder().decode(AdminQueued.self, from: Data(#"{"id":3,"kind":"user","message_id":"m","mail_from":"ada@wren.test","recipients":["b@example.com"],"subject":"Hi","status":"failed","attempts":3,"next_attempt_at":null,"last_error":"550","provider_message_id":null,"created_at":1,"updated_at":2,"provider_name":"SES","user_email":"ada@wren.test"}"#.utf8))
        XCTAssertEqual(queued.lastError, "550")
        XCTAssertEqual(wrenDate(1_000), Date(timeIntervalSince1970: 1))
    }
}
