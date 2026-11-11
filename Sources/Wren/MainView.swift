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
        List(selection: $store.selectedMailbox) {
            ForEach(store.accounts) { account in
                let boxes = store.mailboxes[account.id] ?? []
                Section(account.isPersonal ? "Mailboxes" : account.name) {
                    ForEach(boxes.filter { $0.role != nil }) { box in
                        MailboxRow(mailbox: box).tag(MailboxRef(account: account.id, mailbox: box.id))
                    }
                }
                let labels = boxes.filter { $0.role == nil }
                if !labels.isEmpty {
                    Section(account.isPersonal ? "Labels" : "\(account.name) Labels") {
                        ForEach(labels) { box in
                            MailboxRow(mailbox: box).tag(MailboxRef(account: account.id, mailbox: box.id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // Near the limit, new mail starts bouncing; say so before it does.
            let full = store.quota.flatMap { $0.fraction >= 0.9 ? $0 : nil }
            if store.problem != nil || full != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let problem = store.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .lineLimit(3)
                    }
                    if let full {
                        Label("Storage is \(full.fraction.formatted(.percent.precision(.fractionLength(0)))) full. Delete large messages to keep getting mail.", systemImage: "externaldrive.badge.exclamationmark")
                            .help(storageText(full))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
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
        switch mailbox.role {
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
