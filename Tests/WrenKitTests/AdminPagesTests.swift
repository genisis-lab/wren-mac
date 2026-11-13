import Foundation
import XCTest
@testable import WrenKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The admin panel's pages: what Wren's admin API answers (Fixtures/Admin, dumped from the server's test harness),
/// spreadsheets of people, and files to download or upload.
final class AdminPagesTests: XCTestCase {
    private func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Admin"), name)
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            XCTFail("\(name): \(error)")
            throw error
        }
    }

    private struct Domains: Decodable { var domains: [AdminDomain] }
    private struct Addresses: Decodable { var addresses: [AdminAddress] }
    private struct Shared: Decodable { var mailboxes: [AdminSharedMailbox] }
    private struct Providers: Decodable { var providers: [AdminProvider] }
    private struct Provider: Decodable { var provider: AdminProvider }
    private struct Types: Decodable { var types: [AdminProviderType] }
    private struct Items<T: Decodable>: Decodable { var items: [T] }
    private struct Dmarc: Decodable { var domains: [AdminDmarcDomain] }
    private struct Results<T: Decodable>: Decodable { var results: [T] }
    private struct Users: Decodable { var users: [AdminUser] }

    func testDomainsAndTheirDNS() throws {
        let list = try fixture("domains", as: Domains.self).domains
        let example = try XCTUnwrap(list.first { $0.name == "example.test" })
        XCTAssertEqual(example.providerName, "Resend")
        XCTAssertEqual(example.footerText, "Sent from Example")
        let dns = try XCTUnwrap(example.dns)
        XCTAssertEqual(dns.mx?.ok, false)
        XCTAssertEqual(dns.spf?.host, "send.example.test")
        XCTAssertEqual(dns.spfOK, false)
        XCTAssertEqual(dns.dkimOK, false)
        XCTAssertEqual(dns.dkim?.first?.selector, "resend")

        let detail = try fixture("domain", as: AdminDomainDetail.self)
        XCTAssertEqual(detail.domain.catchAllEmail, "admin@wren.test")
        XCTAssertNil(detail.domain.dns)
        XCTAssertFalse(detail.records.isEmpty)
        XCTAssertTrue(detail.records.allSatisfy { !$0.host.isEmpty && !$0.value.isEmpty })

        let catchAll = try fixture("catchall", as: AdminCatchAll.self)
        XCTAssertEqual(catchAll.hits.first?.address, "postmaster@wren.test")
        XCTAssertEqual(catchAll.hits.first?.blocked, false)
        XCTAssertEqual(try fixture("sending-check", as: AdminSenderCheck.self).provider?.name, "Resend")
        XCTAssertNil(try fixture("sending-check", as: AdminSenderCheck.self).verified)
        XCTAssertEqual(try fixture("cloudflare", as: AdminCloudflare.self).configured, false)
    }

    func testAliasesGroupsAndSharedMailboxes() throws {
        let list = try fixture("addresses", as: Addresses.self).addresses
        let alias = try XCTUnwrap(list.first { $0.address == "hello@wren.test" })
        XCTAssertFalse(alias.isGroup)
        XCTAssertEqual(alias.userEmail, "admin@wren.test")
        let group = try XCTUnwrap(list.first { $0.address == "team@wren.test" })
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.members.map(\.address), ["sam@wren.test", "partner@gmail.com"])
        XCTAssertEqual(group.members.map(\.userId), [2, nil])

        let shared = try fixture("shared-mailboxes", as: Shared.self).mailboxes
        XCTAssertEqual(shared.first?.address, "support@wren.test")
        XCTAssertEqual(shared.first?.members.first?.canSend, false)
    }

    func testProvidersAndTheirSettings() throws {
        let list = try fixture("providers", as: Providers.self).providers
        let resend = try XCTUnwrap(list.first { $0.type == "resend" })
        XCTAssertTrue(resend.isDefault)
        XCTAssertEqual(resend.domains, ["example.test"])
        XCTAssertFalse(resend.hasRecentError)
        // One provider comes with its settings; secrets only masked.
        let config = try XCTUnwrap(try fixture("provider", as: Provider.self).provider.config)
        XCTAssertEqual(config["apiKey"]?.string, "••••••••")

        let types = try fixture("provider-types", as: Types.self).types
        XCTAssertGreaterThan(types.count, 10)
        XCTAssertTrue(types.allSatisfy { t in AdminProviderType.categories.contains { $0.key == t.category } })
        let smtp = try XCTUnwrap(types.first { $0.type == "smtp" })
        XCTAssertEqual(smtp.defaults["port"], .number(587))
        XCTAssertEqual(smtp.fields.first { $0.key == "security" }?.options?.first?.value, "starttls")
        XCTAssertEqual(smtp.presets?.first?.values["host"]?.string, "smtp.gmail.com")
        XCTAssertEqual(try fixture("verify", as: AdminCheckResult.self).ok, false)
    }

    func testLogs() throws {
        let out = try fixture("delivery-log", as: AdminLogPage<AdminDeliveryEntry>.self)
        XCTAssertEqual(out.items.first?.event, "failed")
        XCTAssertEqual(out.items.first?.subject, "Quarterly numbers")
        XCTAssertNil(out.nextBefore)
        let detail = try fixture("delivery-entry", as: AdminDeliveryDetail.self)
        XCTAssertEqual(detail.job?.canRetry, true)
        XCTAssertEqual(detail.job?.recipients, ["bob@elsewhere.example"])
        XCTAssertEqual(detail.timeline.map(\.event), ["deferred", "failed"])
        XCTAssertTrue(detail.headers?.hasPrefix("Message-ID:") == true)

        let inbound = try fixture("inbound-log", as: AdminLogPage<AdminInboundEntry>.self)
        // The catch-all took mail for an address with no mailbox.
        XCTAssertTrue(inbound.items.contains { $0.status == "accepted" && $0.rcptTo == "ghost@wren.test" })
        let one = try fixture("inbound-entry", as: AdminInboundDetail.self)
        XCTAssertEqual(one.delivered?.mailbox, "admin@wren.test")

        let filters = try fixture("log-filters", as: AdminLogFilters.self)
        XCTAssertFalse(filters.users.isEmpty)
        XCTAssertEqual(try fixture("suppressions", as: Items<AdminSuppression>.self).items.first?.reason, "manual")
        XCTAssertEqual(try fixture("blocklist", as: Items<AdminBlocked>.self).items.first?.pattern, "spam.example")
    }

    func testDmarcReports() throws {
        let d = try XCTUnwrap(try fixture("dmarc", as: Dmarc.self).domains.first)
        XCTAssertEqual(d.total, 46)
        XCTAssertEqual(d.passRate, 87)
        XCTAssertEqual(d.failingSources.first?.ip, "198.51.100.7")
        XCTAssertEqual(d.failingSources.first?.dispositions, ["quarantine"])
        let r = try XCTUnwrap(try fixture("dmarc-reports", as: AdminLogPage<AdminDmarcReport>.self).items.first)
        XCTAssertEqual(r.org, "google.com")
        XCTAssertLessThan(r.begin, r.end)
    }

    func testOverviewAlertsAndChecklist() throws {
        let o = try fixture("overview", as: AdminOverview.self)
        XCTAssertEqual(o.users, 2)
        XCTAssertGreaterThan(o.fileBytes, 0)
        XCTAssertNotNil(o.uptime)
        let alerts = try fixture("alerts", as: AdminAlerts.self)
        XCTAssertEqual(alerts.open.first?.severity, "critical")
        let list = try fixture("checklist", as: AdminChecklist.self)
        XCTAssertFalse(list.complete)
        XCTAssertEqual(list.items.first { $0.id == "roundtrip" }?.action?.api, "/api/admin/checklist/roundtrip")
        XCTAssertEqual(list.items.first { $0.id == "auth" }?.action?.href, "/admin/domains/1")
    }

    func testSystemBackupsAndSettings() throws {
        let s = try fixture("system", as: AdminSystem.self)
        XCTAssertFalse(s.version.isEmpty)
        XCTAssertEqual(s.backup?.pointInTime, false)
        let b = try fixture("backups", as: AdminBackups.self)
        XCTAssertEqual(b.settings.keep, 7)
        XCTAssertEqual(b.backups.first?.createdBy, "admin@wren.test")

        let settings = try fixture("settings", as: AdminSettings.self)
        XCTAssertEqual(settings.settings["security.require2fa"]?.string, "none")
        XCTAssertEqual(settings.settings["attachments.blockedTypes"]?.array?.first?.string, "exe")
        XCTAssertEqual(settings.systemSender?.address, "contact@wren.test")
        XCTAssertNotNil(settings.defaults?["retention.trashDays"])
        // Only what changed is saved.
        var draft = settings.settings
        draft["retention.trashDays"] = 45
        draft["instance.name"] = settings.settings["instance.name"]
        XCTAssertEqual(AdminSettings.changes(draft, from: settings.settings), ["retention.trashDays": 45])
    }

    func testPeople() throws {
        let users = try fixture("users", as: Users.self).users
        let sam = try XCTUnwrap(users.first { $0.email == "sam@wren.test" })
        XCTAssertEqual(sam.customQuota, true)
        XCTAssertEqual(sam.legalHold, true)
        XCTAssertNotNil(sam.messages)

        let detail = try fixture("user-detail", as: AdminUserDetail.self)
        XCTAssertEqual(detail.mailHandling?.vacation.message, "Back Monday")
        XCTAssertEqual(detail.exports?.first?.isRunning, true)
        XCTAssertEqual(detail.shared?.first?.email, "support@wren.test")
        XCTAssertEqual(detail.user.legalHold?.note, "Case 12")
        _ = try fixture("admin-detail", as: AdminUserDetail.self)
        XCTAssertEqual(try fixture("bulk", as: Results<AdminBulkResult>.self).results.first?.ok, true)
        let imported = try fixture("import", as: Results<AdminImportResult>.self).results
        XCTAssertEqual(imported.map(\.ok), [true, false])
        XCTAssertEqual(imported.last?.error, "invalid email address")
        // Lists the panel already showed still read.
        _ = try fixture("invites", as: InvitesList.self)
        _ = try fixture("outbox", as: Items<AdminQueued>.self)
        _ = try fixture("audit", as: Items<AdminAuditEntry>.self)
    }

    private struct InvitesList: Decodable { var invites: [AdminInvite] }

    func testMailHandlingSendsClearedDatesAsNull() {
        var h = AdminMailHandling()
        h.vacation.enabled = true
        h.vacation.message = "Away"
        h.forwarding.keep = "archive"
        XCTAssertEqual(h.json["vacation"]?["endAt"], .null)
        XCTAssertEqual(h.json["vacation"]?["message"], "Away")
        XCTAssertEqual(h.json["forwarding"]?["keep"], "archive")
        h.vacation.endAt = 1_800_000_000_000
        XCTAssertEqual(h.json["vacation"]?["endAt"], .number(1_800_000_000_000))
    }

    // MARK: Spreadsheets

    func testCSVReadsQuotesSemicolonsAndLineBreaks() {
        XCTAssertEqual(CSV.parse("a,b\r\n\"x, y\",\"say \"\"hi\"\"\"\n\n\"two\nlines\",z"), [["a", "b"], ["x, y", "say \"hi\""], ["two\nlines", "z"]])
        XCTAssertEqual(CSV.parse("\u{FEFF}email;name\njo@x.test;Jo"), [["email", "name"], ["jo@x.test", "Jo"]])
        let made = CSV.make([["a", "b,c"], ["\"q\"", "line\nbreak"]])
        XCTAssertEqual(made, "a,\"b,c\"\r\n\"\"\"q\"\"\",\"line\nbreak\"\r\n")
        XCTAssertEqual(CSV.parse(made), [["a", "b,c"], ["\"q\"", "line\nbreak"]])
    }

    func testImportRowsFromASpreadsheet() {
        let (rows, warning) = AdminImport.rows(AdminImport.template)
        XCTAssertNil(warning)
        XCTAssertEqual(rows, [
            ["email": "jane@example.com", "name": "Jane Doe", "setupEmail": "jane@gmail.com", "role": "user", "quotaMb": 2048],
            ["email": "sam@example.com", "name": "Sam Lee", "password": "a long temporary passphrase", "role": "admin", "sendLimitPerDay": 500],
        ])
        // Other column names people use, and odd values.
        let other = AdminImport.rows("Email Address,Full Name,Role,Quota\nlee@x.test,Lee,Administrator,abc\n").rows
        XCTAssertEqual(other, [["email": "lee@x.test", "name": "Lee", "role": "admin", "quotaMb": nil]])
        XCTAssertNotNil(AdminImport.rows("name\nJo\n").warning)
    }

    func testPeopleExportAsASpreadsheet() throws {
        let users = try fixture("users", as: Users.self).users
        let rows = CSV.parse(AdminImport.export(users))
        XCTAssertEqual(rows.first?.first, "email")
        XCTAssertEqual(rows.count, users.count + 1)
        let sam = try XCTUnwrap(rows.first { $0.first == "sam@wren.test" })
        XCTAssertEqual(sam[7], "2048")
        XCTAssertEqual(sam[4].count, 10)
    }

    // MARK: Files

    func testFileNameFromTheServer() {
        XCTAssertEqual(JMAPClient.filename(#"attachment; filename="wren-backup-2026-11-13.jsonl""#), "wren-backup-2026-11-13.jsonl")
        XCTAssertEqual(JMAPClient.filename(#"attachment; filename="../../etc/passwd""#), "passwd")
        XCTAssertEqual(JMAPClient.filename("attachment; filename=export.mbox"), "export.mbox")
        XCTAssertNil(JMAPClient.filename(nil))
        XCTAssertNil(JMAPClient.filename("inline"))
    }

    func testDownloadsAndUploadsGoWithTheUnlock() async throws {
        #if canImport(FoundationNetworking)
        // Linux's URLSession crashes on download tasks through a test URLProtocol; Mac CI runs this.
        throw XCTSkip("Download tasks need Apple's URLSession")
        #endif
        let client = JMAPClient(server: URL(string: "https://mail.wren.test/")!, username: "ada@wren.test", password: "app-pw", http: Mock.session)
        let admin = AdminClient(client: client)
        Mock.handler = { request in
            switch request.url?.path {
            case "/jmap/admin/unlock/verify": return ["token": "t0k3n-t0k3n-t0k3n-t0k3n", "role": "owner", "expiresAt": .number(Date().timeIntervalSince1970 * 1000 + 3_600_000), "idleSeconds": 900]
            case "/api/admin/export":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wren-Admin"), "t0k3n-t0k3n-t0k3n-t0k3n")
                return Mock.Reply(status: 200, json: .null, raw: Data("{\"a\":1}\n".utf8), headers: ["Content-Disposition": #"attachment; filename="wren-export.jsonl""#])
            case "/api/admin/restore":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wren"), "1")
                return ["ok": true, "rows": ["users": 2, "messages": 5], "skipped": 0, "exportedAt": 1]
            case "/api/admin/backups/9/download": return Mock.Reply(status: 403, json: ["error": "Only the owner can restore backups"])
            default: return [:]
            }
        }
        // Locked: nothing is sent.
        do {
            _ = try await admin.download("/export")
            XCTFail("needs an unlock")
        } catch AdminError.locked {}
        let challenge = AdminChallenge(secret: "c", role: "owner", steps: [.totp], emailTo: nil, expiresAt: .now.addingTimeInterval(60))
        let unlocked = try await admin.verify(challenge, step: .totp, code: "123456")
        XCTAssertTrue(unlocked)

        let (file, name) = try await admin.download("/export")
        XCTAssertEqual(name, "wren-export.jsonl")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"a\":1}\n")

        let restored = try await admin.upload("/restore", file: file, contentType: "application/x-ndjson")
        let result = try JSONDecoder().decode(AdminRestored.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(result.total, 7)

        do {
            _ = try await admin.download("/backups/9/download")
            XCTFail("refused")
        } catch let error as AdminError {
            XCTAssertEqual(error.errorDescription, "Only the owner can restore backups")
        }
    }
}
