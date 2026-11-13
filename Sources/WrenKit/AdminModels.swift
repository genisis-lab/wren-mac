import Foundation

// What the rest of Wren's admin API answers: domains, addresses, providers, logs, DMARC, alerts, backups and
// settings. Field names follow the server (some lists still answer SQLite's snake_case columns). Anything the
// server may leave out or send as null is optional, so a page still shows when one record is odd.

// MARK: Domains

public struct AdminDomain: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var enabled: Bool
    public var verified: Bool
    public var verifiedAt: Double?
    public var verifyToken: String?
    public var providerId: Int?
    public var providerName: String?
    public var fallbackProviderId: Int?
    public var catchAllUserId: Int?
    public var catchAllEmail: String?
    public var dkimSelector: String?
    public var footerText: String?
    public var mailboxes: Int?
    public var aliases: Int?
    public var dnsCheckedAt: Double?
    public var dns: AdminDNSHealth?
    public var createdAt: Double?
}

/// The last DNS check of a domain. An `ok` of nil means not checked or not needed (MX on a sending-only domain).
public struct AdminDNSHealth: Decodable, Sendable, Hashable {
    public struct Verification: Decodable, Sendable, Hashable { public var ok: Bool?; public var expected: String? }
    public struct MX: Decodable, Sendable, Hashable {
        public struct Record: Decodable, Sendable, Hashable { public var priority: Int?; public var exchange: String }
        public var ok: Bool?
        public var records: [Record]?
        public var hint: String?
    }
    public struct SPF: Decodable, Sendable, Hashable {
        public var ok: Bool?
        public var record: String?
        public var includesProvider: Bool?
        public var expectedInclude: String?
        public var host: String?
    }
    public struct DKIM: Decodable, Sendable, Hashable { public var selector: String; public var found: Bool; public var value: String? }
    public struct DMARC: Decodable, Sendable, Hashable { public var ok: Bool?; public var record: String?; public var policy: String?; public var host: String? }

    public var checkedAt: Double?
    public var verification: Verification?
    public var mx: MX?
    public var spf: SPF?
    public var dkim: [DKIM]?
    public var dmarc: DMARC?
    public var errors: [String]?

    /// SPF counts only with the provider's include, when there is one to check.
    public var spfOK: Bool? { spf?.ok.map { $0 && spf?.includesProvider != false } }
    /// Nil when no selector was checked.
    public var dkimOK: Bool? { (dkim ?? []).isEmpty ? nil : dkim!.contains { $0.found } }
}

/// A record to create at the DNS host.
public struct AdminDNSRecord: Decodable, Sendable, Hashable {
    public var type: String
    public var host: String
    public var value: String
    public var purpose: String?
    public var priority: Int?
    public var optional: Bool?
}

public struct AdminDomainDetail: Decodable, Sendable {
    public var domain: AdminDomain
    public var records: [AdminDNSRecord]
}

/// What a domain's catch-all has been taking, and the addresses blocked on it.
public struct AdminCatchAll: Decodable, Sendable {
    public struct Hit: Decodable, Sendable, Identifiable, Hashable {
        public var address: String
        public var count: Int
        public var firstAt: Double?
        public var lastAt: Double?
        public var lastFrom: String?
        public var lastSubject: String?
        public var blocked: Bool
        public var id: String { address }
    }
    public struct Blocked: Decodable, Sendable, Identifiable, Hashable {
        public var address: String
        public var createdAt: Double?
        public var id: String { address }
    }
    public var catchAllUserId: Int?
    public var hits: [Hit]
    public var blocked: [Blocked]
}

/// What the sending provider says about a domain: verified there (true), missing (false) or unknown (nil).
public struct AdminSenderCheck: Decodable, Sendable {
    public struct Provider: Decodable, Sendable { public var id: Int; public var name: String; public var type: String }
    public var domain: String
    public var provider: Provider?
    public var verified: Bool?
    public var detail: String
}

public struct AdminCloudflare: Decodable, Sendable {
    public var configured: Bool
    public var workerName: String?
}

/// One step of the one-click Cloudflare setup: done, skipped (already done), warn or failed.
public struct AdminSetupStep: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var status: String
    public var detail: String
}

// MARK: Addresses

/// An alias (to one mailbox) or a group (to several people, external addresses too).
public struct AdminAddress: Decodable, Sendable, Identifiable, Hashable {
    public struct Member: Decodable, Sendable, Hashable {
        public var userId: Int?
        public var email: String?
        public var external: String?
        public var address: String { email ?? external ?? "" }
    }
    public var id: Int
    public var address: String
    public var domain: String?
    public var kind: String
    public var name: String
    public var userId: Int?
    public var userEmail: String?
    public var canSend: Bool
    public var enabled: Bool
    public var description: String?
    public var members: [Member]
    public var createdAt: Double?

    public var isGroup: Bool { kind == "group" }
}

/// An inbox a team reads together.
public struct AdminSharedMailbox: Decodable, Sendable, Identifiable, Hashable {
    public struct Member: Decodable, Sendable, Hashable {
        public var userId: Int
        public var email: String
        public var name: String?
        public var canSend: Bool
    }
    public var id: Int
    public var address: String
    public var name: String
    public var status: String
    public var usedBytes: Double?
    public var quotaBytes: Double?
    public var unread: Int?
    public var members: [Member]
}

// MARK: Providers

public struct AdminProvider: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var type: String
    public var typeName: String
    public var enabled: Bool
    public var isDefault: Bool
    public var outbound: Bool
    public var inbound: Bool
    public var inboundUrl: String?
    public var sentCount: Int?
    public var failedCount: Int?
    public var receivedCount: Int?
    public var lastUsedAt: Double?
    public var lastError: String?
    public var lastErrorAt: Double?
    public var domains: [String]
    /// Only when one provider is asked for. Secret fields come back masked, never in the clear.
    public var config: [String: JSON]?

    /// An error since it was last used successfully.
    public var hasRecentError: Bool {
        guard let at = lastErrorAt else { return false }
        return lastUsedAt.map { at > $0 } ?? true
    }
}

/// A kind of provider Wren can connect, and the settings it takes.
public struct AdminProviderType: Decodable, Sendable, Identifiable, Hashable {
    public struct Field: Decodable, Sendable, Hashable, Identifiable {
        public struct Option: Decodable, Sendable, Hashable { public var value: String; public var label: String }
        public var key: String
        public var label: String
        /// text, password, number, select, boolean, textarea or url.
        public var type: String
        public var required: Bool?
        public var placeholder: String?
        public var help: String?
        public var options: [Option]?
        public var `default`: JSON?
        public var inbound: Bool?
        public var id: String { key }
    }
    public struct Preset: Decodable, Sendable, Hashable {
        public var label: String
        public var values: [String: JSON]
    }
    public var type: String
    public var name: String
    public var description: String
    public var website: String?
    public var outbound: Bool
    public var inbound: Bool
    public var fields: [Field]
    public var inboundSetup: String?
    public var eventsSetup: String?
    public var eventsWebhook: Bool?
    public var outboundSetup: String?
    public var category: String
    public var recommended: Bool?
    public var inboundVia: String?
    public var presets: [Preset]?
    public var id: String { type }

    /// A new provider's settings: each field's default, or empty.
    public var defaults: [String: JSON] {
        Dictionary(uniqueKeysWithValues: fields.map { f in (f.key, f.default ?? (f.type == "boolean" ? .bool(false) : .string(""))) })
    }

    /// Where a type is listed, in the order the web shows them.
    public static let categories: [(key: String, title: String)] = [
        ("api", "Email APIs"), ("smtp", "SMTP"), ("self-hosted", "Self-hosted"), ("inbound", "Inbound only"), ("other", "Other"),
    ]
}

/// The answer to checking a provider's credentials or sending a test.
public struct AdminCheckResult: Decodable, Sendable, Hashable {
    public var ok: Bool
    public var message: String
}

// MARK: Logs

/// A page of a log, newest first; `nextBefore` asks for the page after it.
public struct AdminLogPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Item]
    public var nextBefore: Double?
}

/// Something that happened to outgoing mail.
public struct AdminDeliveryEntry: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var event: String
    public var recipients: String?
    public var detail: String?
    public var createdAt: Double
    public var outboxId: Int?
    public var providerName: String?
    public var userEmail: String?
    public var subject: String?
    public var mailFrom: String?
    public var kind: String?
    public var outboxStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, event, recipients, detail, subject, kind
        case createdAt = "created_at", outboxId = "outbox_id", providerName = "provider_name", userEmail = "user_email"
        case mailFrom = "mail_from", outboxStatus = "outbox_status"
    }
}

/// A message that came in, and what Wren did with it.
public struct AdminInboundEntry: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var source: String?
    public var mailFrom: String?
    public var rcptTo: String?
    public var subject: String?
    public var size: Int?
    public var status: String
    public var reason: String?
    public var createdAt: Double
    public var providerName: String?

    enum CodingKeys: String, CodingKey {
        case id, source, subject, size, status, reason
        case mailFrom = "mail_from", rcptTo = "rcpt_to", createdAt = "created_at", providerName = "provider_name"
    }
}

/// One outgoing delivery: the queued message, its timeline and its headers (never the message itself).
public struct AdminDeliveryDetail: Decodable, Sendable {
    public struct Job: Decodable, Sendable {
        public var id: Int
        public var kind: String?
        public var status: String
        public var mailFrom: String?
        public var recipients: [String]?
        public var subject: String?
        public var attempts: Int?
        public var nextAttemptAt: Double?
        public var lastError: String?
        public var providerName: String?
        public var providerMessageId: String?
        public var canRetry: Bool?
        public var canCancel: Bool?
    }
    public var entry: AdminDeliveryEntry
    public var job: Job?
    public var timeline: [AdminDeliveryEntry]
    public var headers: String?
}

public struct AdminInboundDetail: Decodable, Sendable {
    public struct Delivered: Decodable, Sendable {
        public var folder: String?
        public var mailbox: String?
        public var spamScore: Double?
        public var authResults: [String: String]?
    }
    public var entry: AdminInboundEntry
    public var delivered: Delivered?
    public var headers: String?
}

/// What the delivery logs can be filtered by.
public struct AdminLogFilters: Decodable, Sendable {
    public struct User: Decodable, Sendable, Hashable, Identifiable { public var id: Int; public var email: String }
    public var domains: [String]
    public var users: [User]
}

/// An address Wren won't mail: it hard-bounced, reported spam, or an admin added it.
public struct AdminSuppression: Decodable, Sendable, Identifiable, Hashable {
    public var address: String
    public var reason: String
    public var detail: String?
    public var createdAt: Double?
    public var id: String { address }
}

// MARK: DMARC

/// What receivers reported about mail sent as one domain over a period.
public struct AdminDmarcDomain: Decodable, Sendable, Identifiable, Hashable {
    public struct Source: Decodable, Sendable, Hashable, Identifiable {
        public var ip: String
        public var count: Int
        public var headerFrom: [String]
        public var dispositions: [String]
        public var reporters: [String]
        public var id: String { ip }
    }
    public var domain: String
    public var policy: String?
    public var reports: Int
    public var reporters: Int
    public var lastReportAt: Double?
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var passRate: Double?
    public var dkimPassRate: Double?
    public var spfPassRate: Double?
    public var failingSources: [Source]
    public var id: String { domain }
}

public struct AdminDmarcReport: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var org: String
    public var reportId: String?
    public var domain: String
    public var policy: String?
    public var begin: Double
    public var end: Double
    public var messages: Int
    public var passRate: Double?
}

// MARK: Overview extras

public struct AdminAlert: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var kind: String
    public var key: String?
    /// info, warn or critical.
    public var severity: String
    public var title: String
    public var detail: String
    /// A page of the web admin panel that fixes it.
    public var link: String?
    public var createdAt: Double
    public var updatedAt: Double?
    public var resolvedAt: Double?
}

public struct AdminAlerts: Decodable, Sendable {
    public var open: [AdminAlert]
    public var recent: [AdminAlert]?
}

/// A step of getting Wren ready.
public struct AdminChecklistItem: Decodable, Sendable, Identifiable, Hashable {
    public struct Action: Decodable, Sendable, Hashable {
        public var label: String
        /// A page of the web app.
        public var href: String?
        /// Something to POST, under /api/admin.
        public var api: String?
    }
    public var id: String
    public var title: String
    /// done, todo, warn or pending.
    public var status: String
    public var detail: String
    public var action: Action?
    public var optional: Bool?
}

public struct AdminChecklist: Decodable, Sendable {
    public var items: [AdminChecklistItem]
    public var complete: Bool
}

// MARK: System and backups

public struct AdminSystem: Decodable, Sendable {
    public struct Storage: Decodable, Sendable { public var database: Double?; public var blobs: Double? }
    public struct Backup: Decodable, Sendable { public var pointInTime: Bool?; public var searchRebuilding: Bool? }
    /// Mail files from before encryption, still being encrypted (nil once everything is).
    public struct Encrypting: Decodable, Sendable { public var left: Int?; public var skipped: Int?; public var done: Bool? }
    public var version: String
    public var uptime: Double?
    public var publicUrl: String?
    public var storage: Storage?
    public var backup: Backup?
    public var encryptingFiles: Encrypting?
    public var keyMismatch: Bool?
    public var platform: String?
    public var blobStorage: String?
    public var selfHosted: Bool?
    public var emailBindings: [String]?
    public var secretFromEnv: Bool?
}

public struct AdminBackup: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    /// auto or manual.
    public var kind: String
    /// running, done or failed.
    public var status: String
    public var rows: Int?
    public var bytes: Double?
    public var error: String?
    public var createdAt: Double
    public var finishedAt: Double?
    public var createdBy: String?
}

public struct AdminBackups: Decodable, Sendable {
    public struct Settings: Decodable, Sendable { public var enabled: Bool; public var keep: Int; public var hour: Int }
    public var settings: Settings
    public var nextAt: Double?
    public var backups: [AdminBackup]
}

/// What a restore brought back.
public struct AdminRestored: Decodable, Sendable {
    public var exportedAt: Double?
    public var rows: [String: Int]
    public var skipped: Int?
    public var total: Int { rows.values.reduce(0, +) }
}

// MARK: Settings

/// The server's settings, kept as JSON by key ("security.require2fa", …): the page changes them one by one and
/// saves only the keys that changed. Secrets come back masked.
public struct AdminSettings: Decodable, Sendable {
    public struct Sender: Decodable, Sendable { public var address: String; public var name: String }
    public var settings: [String: JSON]
    public var defaults: [String: JSON]?
    public var systemSender: Sender?
    /// This Mac's address as the server sees it (for the admin IP allowlist).
    public var clientIp: String?

    /// The keys whose values differ, with the new values: what to save.
    public static func changes(_ new: [String: JSON], from old: [String: JSON]) -> [String: JSON] {
        new.filter { old[$0.key] != $0.value }
    }
}

public struct AdminBlocked: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var pattern: String
    public var createdAt: Double?
}

// MARK: People

/// An export of someone's mail as .mbox.
public struct AdminExportJob: Decodable, Sendable, Identifiable, Hashable {
    public struct Progress: Decodable, Sendable, Hashable { public var messages: Int?; public var bytes: Double? }
    public var id: Int
    /// queued, running, done, failed or cancelled.
    public var status: String
    public var progress: Progress?
    public var error: String?
    public var createdAt: Double

    public var isRunning: Bool { status == "queued" || status == "running" }
}

/// Out-of-office and forwarding, as an admin sets them for someone who's away or has left.
public struct AdminMailHandling: Codable, Sendable, Equatable {
    public struct Vacation: Codable, Sendable, Equatable {
        public var enabled = false
        public var subject = ""
        public var message = ""
        public var startAt: Double?
        public var endAt: Double?
        public var contactsOnly = false
    }
    public struct Forwarding: Codable, Sendable, Equatable {
        public var enabled = false
        public var to = ""
        /// inbox, read, archive or trash: what happens to their own copy.
        public var keep = "inbox"
    }
    public var vacation = Vacation()
    public var forwarding = Forwarding()

    public init() {}

    /// As the server takes it. A date that was cleared goes as null: left out, the server would keep the old one.
    public var json: JSON {
        let time = { (t: Double?) -> JSON in t.map(JSON.number) ?? .null }
        return [
            "vacation": [
                "enabled": .bool(vacation.enabled), "subject": .string(vacation.subject), "message": .string(vacation.message),
                "startAt": time(vacation.startAt), "endAt": time(vacation.endAt), "contactsOnly": .bool(vacation.contactsOnly),
            ],
            "forwarding": ["enabled": .bool(forwarding.enabled), "to": .string(forwarding.to), "keep": .string(forwarding.keep)],
        ]
    }
}

/// One person's result in a bulk change.
public struct AdminBulkResult: Decodable, Sendable, Hashable {
    public var id: Int?
    public var email: String
    public var ok: Bool
    public var error: String?
}

/// One row's result in an import (or a dry run of it).
public struct AdminImportResult: Decodable, Sendable, Hashable, Identifiable {
    public var row: Int
    public var email: String
    public var ok: Bool
    public var error: String?
    public var setupUrl: String?
    public var id: Int { row }
}
