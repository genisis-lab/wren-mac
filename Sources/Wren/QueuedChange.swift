import Foundation

/// A change to some conversations made while the server couldn't be reached: kept on this Mac (so it survives
/// quitting) and sent when the connection is back. What it does is worked out again then, from the server's mail.
struct QueuedChange: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case move, read, flag, label, snooze }

    var id = UUID()
    var kind: Kind
    /// Where the conversations were when the change was made.
    var place: MailboxRef
    var threadIds: [String]
    /// The folder to move to (a role: inbox, archive, junk, trash).
    var role: String?
    /// Read, flagged or labelled (or not).
    var on: Bool?
    var label: String?
    var until: Date?
    var made = Date.now

    init(_ kind: Kind, in place: MailboxRef, ids: Set<String>, role: String? = nil, on: Bool? = nil, label: String? = nil, until: Date? = nil) {
        self.kind = kind
        self.place = place
        threadIds = ids.sorted()
        self.role = role
        self.on = on
        self.label = label
        self.until = until
    }

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wren/Waiting.json")
    }

    static func load() -> [QueuedChange] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([QueuedChange].self, from: data)) ?? []
    }

    static func save(_ list: [QueuedChange]) {
        if list.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: file, options: .atomic)
    }
}
