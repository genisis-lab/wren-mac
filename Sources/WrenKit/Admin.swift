import Foundation

// The admin panel from the app (docs/jmap.md in genisis-lab/mail, "The admin panel in an app"). The app password
// alone never reaches it: unlocking takes the account password and one second step, and gives a token that lasts
// 15 minutes of use (an hour at most), works only with the same app password, and is kept in memory only.

/// The second steps Wren offers for an unlock.
public enum AdminStep: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A code from the authenticator app (or a recovery code).
    case totp
    /// Approval in a browser signed in to Wren with two factors, by typing the number the app shows.
    case web
    /// A code sent to the confirmed recovery email.
    case email

    public var id: String { rawValue }
}

/// After the account password: what's needed next.
public struct AdminChallenge: Sendable, Equatable {
    let secret: String
    public var role: String
    /// Which second steps this person can use; `emailTo` is where a code would go (masked), if anywhere.
    public var steps: [AdminStep]
    public var emailTo: String?
    public var expiresAt: Date
}

/// An unlocked admin panel.
public struct AdminUnlock: Sendable, Equatable {
    let token: String
    public var role: String
    public var expiresAt: Date
    /// It locks after this long without a request.
    public var idle: TimeInterval
}

public enum AdminError: Error, LocalizedError, Equatable {
    /// The unlock ended (time, Lock, or the server ended it): unlock again.
    case locked
    /// The server is older than this app: it answers only part of the admin panel to apps.
    case webOnly
    case server(Int, String?, code: String?)

    public var errorDescription: String? {
        switch self {
        case .locked: "The admin panel locked. Unlock it again to carry on."
        case .webOnly: "Your Wren server needs an update before the Mac can do this. Until then, use the admin panel on the web."
        case .server(let status, let message, _): message ?? "The server answered with an error (\(status))."
        }
    }

    public var code: String? {
        if case .server(_, _, let code) = self { return code }
        return nil
    }
}

/// Wren's dates in its own API are milliseconds since 1970.
public func wrenDate(_ ms: Double?) -> Date? {
    ms.map { Date(timeIntervalSince1970: $0 / 1000) }
}

/// Unlocking the admin panel, and Wren's admin API with the unlock, for one sign-in.
public actor AdminClient {
    public nonisolated let client: JMAPClient
    public private(set) var unlock: AdminUnlock?
    private var lastUse = Date.distantPast

    public init(client: JMAPClient) {
        self.client = client
    }

    /// Unlocked, and not timed out on this side.
    public var isUnlocked: Bool {
        guard let unlock else { return false }
        return unlock.expiresAt > .now && Date.now.timeIntervalSince(lastUse) < unlock.idle
    }

    /// When it locks if nothing more is done: the idle limit or the hard one, whichever comes first.
    public var locksAt: Date? {
        guard let unlock else { return nil }
        return min(unlock.expiresAt, lastUse.addingTimeInterval(unlock.idle))
    }

    // MARK: Unlocking

    /// Step one: the account password (never the app password). `device` names this Mac in the approval request.
    public func start(password: String, device: String) async throws -> AdminChallenge {
        let r = try await post("/jmap/admin/unlock", ["password": .string(password), "device": .string(device)])
        guard let secret = r["challenge"]?.string, let steps = r["steps"] else { throw JMAPError.badResponse }
        var available: [AdminStep] = []
        if steps["totp"]?.bool == true { available.append(.totp) }
        if steps["web"]?.bool == true { available.append(.web) }
        if steps["email"]?.string != nil { available.append(.email) }
        return AdminChallenge(
            secret: secret, role: r["role"]?.string ?? "admin", steps: available, emailTo: steps["email"]?.string,
            expiresAt: wrenDate(r["expiresAt"]?.number) ?? .now.addingTimeInterval(600)
        )
    }

    /// Ask for approval on the web: answers the number to type there, and the page to type it on.
    public func askWeb(_ challenge: AdminChallenge) async throws -> (number: Int, page: URL?) {
        let r = try await post("/jmap/admin/unlock/web", ["challenge": .string(challenge.secret)])
        guard let number = r["number"]?.int else { throw JMAPError.badResponse }
        return (number, r["url"]?.string.flatMap(URL.init(string:)))
    }

    /// Email a code to the recovery address. Answers where it went (masked).
    public func sendEmailCode(_ challenge: AdminChallenge) async throws -> String {
        let r = try await post("/jmap/admin/unlock/email", ["challenge": .string(challenge.secret)])
        return r["sentTo"]?.string ?? challenge.emailTo ?? "your recovery email"
    }

    /// Step two. True once unlocked; false while a web approval is still waiting (ask again in a few seconds).
    public func verify(_ challenge: AdminChallenge, step: AdminStep, code: String? = nil) async throws -> Bool {
        var body: [String: JSON] = ["challenge": .string(challenge.secret), "step": .string(step.rawValue)]
        if let code { body["code"] = .string(code) }
        let (status, data) = try await client.request("POST", path: "/jmap/admin/unlock/verify", body: .object(body))
        let r = try Self.check(status, data)
        if status == 202 { return false }
        guard let token = r["token"]?.string else { throw JMAPError.badResponse }
        unlock = AdminUnlock(
            token: token, role: r["role"]?.string ?? challenge.role,
            expiresAt: wrenDate(r["expiresAt"]?.number) ?? .now.addingTimeInterval(3600),
            idle: r["idleSeconds"]?.number ?? 900
        )
        lastUse = .now
        return true
    }

    /// Lock: forget the token here and end it on the server.
    public func lock() async {
        let had = unlock != nil
        unlock = nil
        if had { _ = try? await client.request("POST", path: "/jmap/admin/lock", body: .object([:])) }
    }

    // MARK: The admin API

    public func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try await JSONDecoder().decode(T.self, from: admin("GET", path, nil))
    }

    /// A change (POST, PUT or DELETE). Answers the server's reply.
    @discardableResult
    public func send(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
        let payload: JSON? = method == "DELETE" ? body : (body ?? .object([:]))
        let data = try await admin(method, path, payload)
        return data.isEmpty ? .null : try JSONDecoder().decode(JSON.self, from: data)
    }

    /// Download an export or a backup to a temporary file: answers it and the name the server suggests.
    public func download(_ path: String) async throws -> (file: URL, filename: String?) {
        let token = try await token()
        let (status, file, filename) = try await client.transfer("GET", path: "/api/admin" + path, headers: ["X-Wren-Admin": token])
        try finish(status, file)
        return (file, filename)
    }

    /// Send a file as the request body (an export to restore). Answers the server's reply.
    public func upload(_ path: String, file: URL, contentType: String) async throws -> JSON {
        let token = try await token()
        let (status, saved, _) = try await client.transfer("POST", path: "/api/admin" + path, upload: file, contentType: contentType, headers: ["X-Wren-Admin": token])
        defer { try? FileManager.default.removeItem(at: saved) }
        try finish(status, saved)
        return (try? JSONDecoder().decode(JSON.self, from: Data(contentsOf: saved))) ?? .null
    }

    private func token() async throws -> String {
        guard let unlock, isUnlocked else {
            await lock()
            throw AdminError.locked
        }
        return unlock.token
    }

    /// A transfer's answer: an error's body is small JSON, read from the file and then removed.
    private func finish(_ status: Int, _ file: URL) throws {
        if !(200..<300).contains(status) {
            let data = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            try checked(status, data)
        }
        lastUse = .now
    }

    private func admin(_ method: String, _ path: String, _ body: JSON?) async throws -> Data {
        let token = try await token()
        let (status, data) = try await client.request(method, path: "/api/admin" + path, body: body, headers: ["X-Wren-Admin": token])
        try checked(status, data)
        lastUse = .now
        return data
    }

    /// The server's error, if it answered one; an ended unlock is forgotten here too.
    private func checked(_ status: Int, _ data: Data) throws {
        do {
            _ = try Self.check(status, data)
        } catch AdminError.locked {
            self.unlock = nil
            throw AdminError.locked
        }
    }

    private func post(_ path: String, _ body: [String: JSON]) async throws -> JSON {
        let (status, data) = try await client.request("POST", path: path, body: .object(body))
        return try Self.check(status, data)
    }

    /// The reply, or the error it holds: Wren's API answers `{ error, code }`, its JMAP side `{ detail }`.
    static func check(_ status: Int, _ data: Data) throws -> JSON {
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (200..<300).contains(status) else {
            let code = json["code"]?.string
            if code == "admin_locked" { throw AdminError.locked }
            if code == "admin_web_only" { throw AdminError.webOnly }
            throw AdminError.server(status, json["error"]?.string ?? json["detail"]?.string, code: code)
        }
        return json
    }
}

extension JSON {
    public var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

// MARK: What the admin API answers

/// A count that may be missing (SQLite's SUM of nothing is null).
private func count(_ c: KeyedDecodingContainer<AnyKey>, _ key: String) -> Int {
    (try? c.decodeIfPresent(Double.self, forKey: AnyKey(key))).flatMap { $0 }.map { Int($0) } ?? 0
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public struct AdminOverview: Decodable, Sendable {
    public struct Warning: Decodable, Sendable, Hashable {
        public var level: String
        public var message: String
    }

    public struct Day: Decodable, Sendable, Hashable {
        public var date: Double
        public var received: Int
        public var sent: Int
        public var failed: Int
    }

    public struct Flagged: Decodable, Sendable, Hashable {
        public var id: Int
        public var email: String
        public var failed: Int?
        public var newLocation: Int?
    }

    public var version: String
    public var users = 0, activeUsers = 0, suspendedUsers = 0, admins = 0
    public var domains = 0, verifiedDomains = 0
    public var queued = 0, sending = 0, failed24h = 0
    public var received24h = 0, sent24h = 0, rejected24h = 0, spam24h = 0
    public var failedSignIns24h = 0, newLocationSignIns7d = 0
    public var flagged: [Flagged] = []
    public var series: [Day] = []
    public var warnings: [Warning] = []
    public var databaseBytes: Double = 0, fileBytes: Double = 0
    /// Since the server started, in milliseconds.
    public var uptime: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        version = (try? c.decode(String.self, forKey: AnyKey("version"))) ?? ""
        if let u = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("users")) {
            users = count(u, "total"); activeUsers = count(u, "active"); suspendedUsers = count(u, "suspended"); admins = count(u, "admins")
        }
        if let d = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("domains")) {
            domains = count(d, "total"); verifiedDomains = count(d, "verified")
        }
        if let q = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("queue")) {
            queued = count(q, "queued"); sending = count(q, "sending"); failed24h = count(q, "failed24h")
        }
        if let l = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("last24")) {
            received24h = count(l, "received"); sent24h = count(l, "sent"); rejected24h = count(l, "rejected"); spam24h = count(l, "spam")
        }
        if let s = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("signIns")) {
            failedSignIns24h = count(s, "failed24h"); newLocationSignIns7d = count(s, "newLocation7d")
            flagged = (try? s.decode([Flagged].self, forKey: AnyKey("users"))) ?? []
        }
        if let st = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("storage")) {
            databaseBytes = (try? st.decode(Double.self, forKey: AnyKey("database"))) ?? 0
            fileBytes = (try? st.decode(Double.self, forKey: AnyKey("blobs"))) ?? 0
        }
        uptime = try? c.decode(Double.self, forKey: AnyKey("uptime"))
        series = (try? c.decode([Day].self, forKey: AnyKey("series"))) ?? []
        warnings = (try? c.decode([Warning].self, forKey: AnyKey("warnings"))) ?? []
    }
}

/// A person in the Users list.
public struct AdminUser: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var email: String
    public var name: String
    public var role: String
    public var status: String
    public var usedBytes: Double?
    public var quotaBytes: Double?
    public var customQuota: Bool?
    public var sendLimitPerDay: Int?
    public var customSendLimit: Bool?
    public var totpEnabled: Bool?
    public var lastLoginAt: Double?
    public var createdAt: Double?
    public var recoveryEmail: String?
    public var mustChangePassword: Bool?
    public var mailAppsBlocked: Bool?
    public var legalHold: Bool?
    /// Locked out for now by too many wrong passwords.
    public var locked: Bool?
    public var aliases: Int?
    public var messages: Int?

    public var isSuspended: Bool { status == "suspended" }
}

/// Everything the user page shows about one person.
public struct AdminUserDetail: Decodable, Sendable {
    public struct User: Decodable, Sendable {
        public struct Hold: Decodable, Sendable { public var since: Double; public var note: String? }
        public var id: Int
        public var email: String
        public var name: String
        public var role: String
        public var status: String
        public var createdAt: Double?
        public var lastLoginAt: Double?
        public var passwordChangedAt: Double?
        public var mustChangePassword: Bool?
        public var totpEnabled: Bool?
        public var passkeys: Int?
        public var recoveryEmail: String?
        public var recoveryVerified: Bool?
        public var usedBytes: Double?
        public var quotaBytes: Double?
        public var customQuota: Bool?
        public var sendLimitPerDay: Int?
        public var customSendLimit: Bool?
        public var sentToday: Int?
        public var lockedUntil: Double?
        public var legalHold: Hold?
        public var sendPausedAt: Double?
        public var sendPausedReason: String?
    }

    public struct MailApps: Decodable, Sendable {
        public struct Password: Decodable, Sendable, Identifiable {
            public var id: Int
            public var name: String
            public var lastUsedAt: Double?
            public var createdAt: Double?
        }
        public var enabled: Bool
        public var allowed: Bool
        public var passwords: [Password]?
    }

    public struct Shared: Decodable, Sendable, Identifiable {
        public var id: Int
        public var email: String
        public var name: String?
        public var canSend: Bool
    }

    public struct Session: Decodable, Sendable, Identifiable {
        public var id: String
        public var ip: String?
        public var userAgent: String?
        public var createdAt: Double?
        public var lastSeenAt: Double?
    }

    public struct SignIn: Decodable, Sendable, Identifiable {
        public var id: Int
        public var ok: Bool
        public var method: String
        public var reason: String?
        public var ip: String?
        public var country: String?
        public var userAgent: String?
        public var newLocation: Bool?
        public var at: Double
    }

    public struct Address: Decodable, Sendable, Identifiable {
        public var id: Int
        public var address: String
        public var kind: String
    }

    public var user: User
    public var mailApps: MailApps?
    public var sessions: [Session]
    public var signIns: [SignIn]
    public var addresses: [Address]
    /// Not for helpdesk staff: they see account support details only.
    public var mailHandling: AdminMailHandling?
    public var exports: [AdminExportJob]?
    public var shared: [Shared]?
}

public struct AdminInvite: Decodable, Sendable, Identifiable {
    public var id: Int
    public var email: String?
    public var role: String
    public var expiresAt: Double
    public var usedAt: Double?
    public var createdAt: Double
    public var sentTo: String?
    public var usedByEmail: String?

    enum CodingKeys: String, CodingKey {
        case id, email, role
        case expiresAt = "expires_at", usedAt = "used_at", createdAt = "created_at", sentTo = "sent_to", usedByEmail = "used_by_email"
    }
}

/// A message in the outgoing queue.
public struct AdminQueued: Decodable, Sendable, Identifiable {
    public var id: Int
    public var kind: String?
    public var from: String?
    public var recipients: [String]
    public var subject: String?
    public var status: String
    public var attempts: Int?
    public var lastError: String?
    public var updatedAt: Double?
    public var provider: String?
    public var userEmail: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, recipients, subject, status, attempts
        case from = "mail_from", lastError = "last_error", updatedAt = "updated_at", provider = "provider_name", userEmail = "user_email"
    }
}

/// An entry in the audit log.
public struct AdminAuditEntry: Decodable, Sendable, Identifiable {
    public var id: Int
    public var action: String
    public var target: String?
    public var details: JSON?
    public var ip: String?
    public var createdAt: Double
    public var userEmail: String?

    enum CodingKeys: String, CodingKey {
        case id, action, target, details, ip
        case createdAt = "created_at", userEmail = "user_email"
    }

    /// Whether it was done from an app's unlock.
    public var viaApp: Bool { details?["via"]?.string == "app" }
}
