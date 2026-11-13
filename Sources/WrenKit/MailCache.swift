import Foundation

/// Mail kept on disk for one sign-in, so the app opens with mail showing and still shows it offline:
/// the accounts and mailboxes, the last list of each mailbox looked at, and the conversations opened most recently.
public struct MailCache: Sendable {
    /// What the sidebar needs.
    public struct State: Codable, Sendable {
        public var accounts: [Account]
        public var mailboxes: [String: [Mailbox]]
        public var identities: [String: [Identity]]

        public init(accounts: [Account], mailboxes: [String: [Mailbox]], identities: [String: [Identity]]) {
            self.accounts = accounts
            self.mailboxes = mailboxes
            self.identities = identities
        }
    }

    public struct List: Codable, Sendable {
        public var conversations: [Conversation]
        public var total: Int

        public init(conversations: [Conversation], total: Int) {
            self.conversations = conversations
            self.total = total
        }
    }

    /// Copies of this cache share a lifetime. Late requests cannot recreate a signed-out account's files.
    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true

        func whileActive<T>(_ work: () -> T) -> T? {
            lock.lock()
            defer { lock.unlock() }
            guard active else { return nil }
            return work()
        }

        func invalidate(_ work: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard active else { return }
            active = false
            work()
        }
    }

    private let lifetime = Lifetime()
    public let folder: URL
    /// How many opened conversations to keep.
    public let keep: Int

    public init(folder: URL, keep: Int = 150) {
        self.folder = folder
        self.keep = keep
    }

    /// Ids as file names (Wren's are letters and digits already; anything else is escaped).
    private func file(_ parts: String...) -> URL {
        parts.reduce(folder) { $0.appendingPathComponent($1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $1) }
            .appendingPathExtension("json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        // A cache: if it can't be written, the app still works from the server.
        lifetime.whileActive {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        lifetime.whileActive {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        } ?? nil
    }

    public var state: State? {
        get { read(State.self, from: file("state")) }
        nonmutating set { if let newValue { write(newValue, to: file("state")) } }
    }

    public func list(account: String, mailbox: String) -> List? {
        read(List.self, from: file("lists", account, mailbox))
    }

    public func saveList(_ list: List, account: String, mailbox: String) {
        write(list, to: file("lists", account, mailbox))
    }

    public func thread(_ id: String) -> [Email]? {
        read([Email].self, from: file("threads", id))
    }

    /// Keep a conversation, and forget the ones opened longest ago beyond `keep`.
    public func saveThread(_ emails: [Email], id: String) {
        write(emails, to: file("threads", id))
        lifetime.whileActive {
            let folder = folder.appendingPathComponent("threads")
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            guard files.count > keep else { return }
            let date = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            for old in files.sorted(by: { date($0) > date($1) }).dropFirst(max(0, keep)) { try? FileManager.default.removeItem(at: old) }
        }
    }

    /// Everything, for signing out. This instance and its copies cannot be used again; a new sign-in gets a new cache.
    public func delete() {
        lifetime.invalidate { try? FileManager.default.removeItem(at: folder) }
    }
}
