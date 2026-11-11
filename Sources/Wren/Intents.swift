import AppIntents
import AppKit
import WrenKit

/// Actions for Shortcuts, Spotlight and Siri. A message is written from the account Wren is showing (or the first one).

struct SendEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Email"
    static let description = IntentDescription("Writes an email from your Wren account, and opens it for you to finish or sends it straight away.")

    @Parameter(title: "To", description: "Addresses, separated by commas.")
    var to: String

    @Parameter(title: "Subject", default: "")
    var subject: String

    @Parameter(title: "Body", default: "", inputOptions: String.IntentInputOptions(multiline: true))
    var body: String

    @Parameter(title: "Show Compose Window", description: "Open the message to check it before it's sent, rather than sending it now.", default: true)
    var showCompose: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send email to \(\.$to)") {
            \.$subject
            \.$body
            \.$showCompose
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = MailStore.shared
        guard await store.ready(), var draft = store.newDraft() else { throw WrenIntentError.notSignedIn }
        draft.to = to
        draft.subject = subject
        draft.body = body + draft.body
        if showCompose {
            store.openWindow?(id: "compose", value: draft)
            NSApp.activate()
        } else {
            _ = try draft.recipients
            let saved = try await store.save(draft)
            try await store.send(draft, savedAs: saved)
        }
        return .result()
    }
}

struct UnreadCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Unread Count"
    static let description = IntentDescription("How many unread messages are in your Inboxes.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let store = MailStore.shared
        guard await store.ready() else { throw WrenIntentError.notSignedIn }
        await store.refresh()
        let unread = store.unreadInInboxes
        return .result(value: unread, dialog: "\(unread) unread")
    }
}

enum MailboxKind: String, AppEnum {
    case inbox, drafts, sent, archive, snoozed, junk, trash

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mailbox"
    static let caseDisplayRepresentations: [MailboxKind: DisplayRepresentation] = [
        .inbox: "Inbox", .drafts: "Drafts", .sent: "Sent", .archive: "Archive", .snoozed: "Snoozed", .junk: "Spam", .trash: "Trash",
    ]
}

struct OpenMailboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mailbox"
    static let description = IntentDescription("Opens Wren to a mailbox. The Inbox is All Inboxes when you have several accounts.")
    static let openAppWhenRun = true

    @Parameter(title: "Mailbox", default: .inbox)
    var mailbox: MailboxKind

    init() {}

    init(mailbox: MailboxKind) {
        self.mailbox = mailbox
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = MailStore.shared
        guard await store.ready() else { throw WrenIntentError.notSignedIn }
        store.select(role: mailbox.rawValue)
        return .result()
    }
}

struct WrenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendEmailIntent(), phrases: ["Send an email with \(.applicationName)", "Write an email in \(.applicationName)"],
                    shortTitle: "Send Email", systemImageName: "paperplane")
        AppShortcut(intent: UnreadCountIntent(), phrases: ["How much unread mail is in \(.applicationName)", "Get unread count in \(.applicationName)"],
                    shortTitle: "Unread Count", systemImageName: "envelope.badge")
        AppShortcut(intent: OpenMailboxIntent(), phrases: ["Open \(\.$mailbox) in \(.applicationName)", "Show my \(\.$mailbox) in \(.applicationName)"],
                    shortTitle: "Open Mailbox", systemImageName: "tray")
    }
}

enum WrenIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn

    var localizedStringResource: LocalizedStringResource { "Open Wren and sign in first." }
}
