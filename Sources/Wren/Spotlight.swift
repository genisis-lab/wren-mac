import CoreSpotlight
import UniformTypeIdentifiers
import WrenKit

/// Conversations in Spotlight (who from, subject and preview), from the mailboxes you look at. Each sign-in's are a
/// domain of their own, deleted when it's removed. Choosing one opens it in Wren (RootView).
enum Spotlight {
    static func index(_ conversations: [Conversation], in place: MailboxRef) {
        let items = conversations.map { c in
            let about = CSSearchableItemAttributeSet(contentType: .emailMessage)
            about.title = c.email.subject
            about.displayName = c.email.subject
            about.contentDescription = c.email.preview
            about.authorNames = c.email.from?.map(\.displayName)
            about.authorEmailAddresses = c.email.from?.map(\.email)
            about.contentCreationDate = c.email.receivedAt
            return CSSearchableItem(uniqueIdentifier: id(c.id, in: place), domainIdentifier: place.login, attributeSet: about)
        }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// The sign-in, account and conversation: one item per conversation, whichever mailboxes it was seen in.
    static func id(_ threadId: String, in place: MailboxRef) -> String {
        [place.login, place.account, threadId].joined(separator: "\n")
    }

    static func found(_ id: String) -> (login: String, account: String, threadId: String)? {
        let parts = id.components(separatedBy: "\n")
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }

    static func forget(_ id: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id])
    }

    static func forget(login: String) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [login])
    }
}
