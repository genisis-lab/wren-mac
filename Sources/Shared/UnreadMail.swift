import Foundation

/// Unread mail in each Inbox, which the app writes for the widget into the App Group they share.
struct UnreadMail: Codable, Equatable {
    struct Inbox: Codable, Equatable {
        var name: String
        var unread: Int
    }

    var inboxes: [Inbox]

    var total: Int { inboxes.reduce(0) { $0 + $1.unread } }

    /// The App Group's defaults. A group needs a team ID, so there's none when Wren is signed for this Mac only
    /// (WrenTeam in Info.plist is the DEVELOPMENT_TEAM it was built with).
    static var defaults: UserDefaults? {
        guard let team = Bundle.main.object(forInfoDictionaryKey: "WrenTeam") as? String, !team.isEmpty else { return nil }
        return UserDefaults(suiteName: "\(team).io.github.genisis-lab.wren")
    }

    static func load() -> UnreadMail? {
        defaults?.data(forKey: "unread").flatMap { try? JSONDecoder().decode(UnreadMail.self, from: $0) }
    }

    func save() {
        Self.defaults?.set(try? JSONEncoder().encode(self), forKey: "unread")
    }
}
