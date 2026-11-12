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
        .searchScopes($store.searchScope) {
            Text("All Mailboxes").tag(MailStore.SearchScope.everywhere)
            Text(store.mailbox(store.selectedMailbox)?.name ?? "This Mailbox").tag(MailStore.SearchScope.mailbox)
        }
        .onAppear { store.undoManager = undoManager }
        .sheet(item: $store.labelEditor) { LabelSheet(edit: $0) }
        .confirmationDialog(
            "Delete the label “\(store.mailbox(store.confirmingDeleteLabel)?.name ?? "")”?",
            isPresented: Binding(get: { store.confirmingDeleteLabel != nil }, set: { if !$0 { store.confirmingDeleteLabel = nil } }),
            titleVisibility: .visible,
            presenting: store.confirmingDeleteLabel
        ) { ref in
            Button("Delete Label", role: .destructive) { Task { await store.deleteLabel(ref) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its mail stays where it is; only the label comes off.")
        }
        .sheet(isPresented: $store.showingScheduled) { ScheduledView() }
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
        .confirmationDialog(
            "Delete everything in \(store.mailbox(store.confirmingEmpty)?.name ?? "this mailbox") forever?",
            isPresented: Binding(get: { store.confirmingEmpty != nil }, set: { if !$0 { store.confirmingEmpty = nil } }),
            titleVisibility: .visible,
            presenting: store.confirmingEmpty
        ) { ref in
            Button("Delete Forever", role: .destructive) { Task { await store.empty(ref) } }
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
                    .contextMenu { MailboxActions(ref: .allInboxes) }
            }
            ForEach(store.logins) { login in
                ForEach(login.accounts) { account in
                    let boxes = login.mailboxes[account.id] ?? []
                    // Your own mail is "Mailboxes" with one sign-in, and the address with several; shared mailboxes go by their name.
                    let title = account.isPersonal ? (several ? login.username : "Mailboxes") : account.name
                    Section(title) {
                        ForEach(boxes.filter { $0.role != nil }) { box in
                            let ref = MailboxRef(login: login.id, account: account.id, mailbox: box.id)
                            MailboxRow(mailbox: box).tag(ref)
                                .contextMenu { MailboxActions(ref: ref) }
                                .modifier(DropConversations(ref: ref))
                        }
                    }
                    let labels = boxes.filter { $0.role == nil }
                    if !labels.isEmpty {
                        Section(account.isPersonal && !several ? "Labels" : "\(title) Labels") {
                            ForEach(labels) { box in
                                let ref = MailboxRef(login: login.id, account: account.id, mailbox: box.id)
                                MailboxRow(mailbox: box).tag(ref)
                                    .contextMenu { MailboxActions(ref: ref) }
                                    .modifier(DropConversations(ref: ref))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let pending = store.pendingSend { UndoSendBar(pending: pending) }
                notesView
            }
        }
    }

    @ViewBuilder
    private var notesView: some View {
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
            let waiting = store.queuedCount(login)
            if waiting > 0 {
                notes.append(Note(text: who + (waiting == 1 ? "1 change" : "\(waiting) changes") + " waiting for the connection", icon: "arrow.triangle.2.circlepath",
                                  help: "What you did offline is sent to Wren when it can be reached again."))
            }
            if let quota = login.quota, quota.fraction >= 0.9 {
                let full = quota.fraction.formatted(.percent.precision(.fractionLength(0)))
                notes.append(Note(text: who + "Storage is \(full) full. Delete large messages to keep getting mail.", icon: "externaldrive.badge.exclamationmark", help: storageText(quota)))
            }
            return notes
        }
    }
}

/// A message that was just sent, held for a few seconds: Undo stops it and opens it again.
struct UndoSendBar: View {
    let pending: PendingSend
    @Environment(MailStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane")
            // Counts down to when it goes.
            Text(timerInterval: Date.now...max(Date.now, pending.until), countsDown: true)
                .monospacedDigit()
                .frame(width: 34, alignment: .leading)
            Text(pending.draft.subject.isEmpty ? "Sending" : "Sending “\(pending.draft.subject)”")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Undo") { Task { await store.undoSend(pending) } }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Undo Send") { Task { await store.undoSend(pending) } }
    }
}

/// Conversations dragged from the list onto a sidebar mailbox: moved there, or labelled.
struct DropConversations: ViewModifier {
    let ref: MailboxRef
    @Environment(MailStore.self) private var store
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: String.self) { items, _ in
                let ids = MailStore.dropped(items)
                guard !ids.isEmpty, store.canDrop(on: ref) else { return false }
                Task { await store.drop(ids, on: ref) }
                return true
            } isTargeted: { targeted = $0 && store.canDrop(on: ref) }
            .listRowBackground(targeted ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)) : nil)
    }
}

/// Naming a new label, or renaming one.
struct LabelSheet: View {
    let edit: LabelEdit
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(edit.label == nil ? "New Label" : "Rename Label").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(edit.label == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || name == edit.name)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { name = edit.name }
    }

    private func save() {
        guard !working, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                try await store.saveLabel(edit, name: name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// What a mailbox's right-click menu offers.
struct MailboxActions: View {
    let ref: MailboxRef
    @Environment(MailStore.self) private var store

    var body: some View {
        let box = store.mailbox(ref)
        Button("Mark All as Read") { Task { await store.markAllRead(in: ref) } }
            .disabled((box?.unreadEmails ?? 0) == 0)
        if ref != .allInboxes, let role = box?.role, role == "trash" || role == "junk" {
            Divider()
            Button(role == "trash" ? "Empty Trash…" : "Empty Junk…") { store.confirmingEmpty = ref }
                .disabled((box?.totalEmails ?? 0) == 0)
        }
        if ref != .allInboxes {
            Divider()
            Button("New Label…") { store.labelEditor = LabelEdit(login: ref.login, account: ref.account) }
            if let box, box.role == nil {
                Button("Rename Label…") { store.labelEditor = LabelEdit(login: ref.login, account: ref.account, label: box.id, name: box.name) }
                Button("Delete Label…") { store.confirmingDeleteLabel = ref }
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
