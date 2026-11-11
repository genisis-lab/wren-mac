import SwiftUI
import WrenKit

/// Mailboxes, conversations and the reader, side by side, as in Mail.
struct MainView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            ConversationList()
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 560)
        } detail: {
            ReaderPane()
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search")
        .onAppear { store.undoManager = undoManager }
        .alert("Something went wrong", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
        .confirmationDialog(
            "Delete these conversations forever?",
            isPresented: Binding(get: { store.confirmingDelete != nil }, set: { if !$0 { store.confirmingDelete = nil } }),
            titleVisibility: .visible,
            presenting: store.confirmingDelete
        ) { ids in
            Button("Delete Forever", role: .destructive) { Task { await store.deleteForever(ids) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can’t undo this.")
        }
    }
}

struct Sidebar: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let several = store.logins.count > 1
        List(selection: $store.selectedMailbox) {
            if several, let all = store.mailbox(.allInboxes) {
                MailboxRow(mailbox: all).tag(MailboxRef.allInboxes)
            }
            ForEach(store.logins) { login in
                ForEach(login.accounts) { account in
                    let boxes = login.mailboxes[account.id] ?? []
                    // Your own mail is "Mailboxes" with one sign-in, and the address with several; shared mailboxes go by their name.
                    let title = account.isPersonal ? (several ? login.username : "Mailboxes") : account.name
                    Section(title) {
                        ForEach(boxes.filter { $0.role != nil }) { box in
                            MailboxRow(mailbox: box).tag(MailboxRef(login: login.id, account: account.id, mailbox: box.id))
                        }
                    }
                    let labels = boxes.filter { $0.role == nil }
                    if !labels.isEmpty {
                        Section(account.isPersonal && !several ? "Labels" : "\(title) Labels") {
                            ForEach(labels) { box in
                                MailboxRow(mailbox: box).tag(MailboxRef(login: login.id, account: account.id, mailbox: box.id))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes, id: \.text) { note in
                        Label(note.text, systemImage: note.icon)
                            .lineLimit(3)
                            .help(note.help)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        }
    }

    private struct Note {
        var text: String
        var icon: String
        var help: String
    }

    /// Connection problems, and storage near the limit (where new mail starts bouncing), for each sign-in.
    private var notes: [Note] {
        store.logins.flatMap { login -> [Note] in
            let who = store.logins.count > 1 ? "\(login.username): " : ""
            var notes: [Note] = []
            if let problem = login.problem { notes.append(Note(text: who + problem, icon: "exclamationmark.triangle", help: problem)) }
            if let quota = login.quota, quota.fraction >= 0.9 {
                let full = quota.fraction.formatted(.percent.precision(.fractionLength(0)))
                notes.append(Note(text: who + "Storage is \(full) full. Delete large messages to keep getting mail.", icon: "externaldrive.badge.exclamationmark", help: storageText(quota)))
            }
            return notes
        }
    }
}

struct MailboxRow: View {
    let mailbox: Mailbox

    var body: some View {
        Label(mailbox.name, systemImage: icon)
            .badge(count)
    }

    /// Unread counts where they help; Drafts shows how many there are, as Mail does.
    private var count: Int {
        switch mailbox.role {
        case "drafts": mailbox.totalEmails
        case "sent", "archive", "trash": 0
        default: mailbox.unreadEmails
        }
    }

    private var icon: String {
        if mailbox.id == MailboxRef.allInboxes.mailbox { return "tray.2" }
        return switch mailbox.role {
        case "inbox": "tray"
        case "archive": "archivebox"
        case "drafts": "doc"
        case "sent": "paperplane"
        case "junk": "xmark.bin"
        case "trash": "trash"
        case "snoozed": "moon.zzz"
        case nil: "tag"
        default: "folder"
        }
    }
}

/// "1.2 GB of 5 GB used"
func storageText(_ quota: Quota) -> String {
    let used = Int64(quota.used).formatted(.byteCount(style: .file))
    guard quota.hardLimit > 0 else { return "\(used) used" }
    return "\(used) of \(Int64(quota.hardLimit).formatted(.byteCount(style: .file))) used"
}
