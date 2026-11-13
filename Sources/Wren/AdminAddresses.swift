import SwiftUI
import WrenKit

/// Admin → Aliases & Groups: addresses that deliver to one mailbox or to several people, and shared mailboxes.
struct AdminAddressesPage: View {
    @Bindable var panel: AdminPanel
    @State private var tab = Tab.addresses

    enum Tab: String { case addresses, shared }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Aliases & Groups").tag(Tab.addresses)
                Text("Shared Mailboxes").tag(Tab.shared)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(10)
            switch tab {
            case .addresses: AliasesList(panel: panel)
            case .shared: SharedList(panel: panel)
            }
        }
    }
}

/// What the address editors need to know: the domains to make addresses on and the people to deliver to.
private struct Directory {
    var domains: [AdminDomain] = []
    var people: [AdminUser] = []

    static func load(_ panel: AdminPanel) async -> Directory {
        Directory(
            domains: await panel.fetch("/domains", as: DomainList.self)?.domains ?? [],
            people: await panel.fetch("/users", as: UserList.self)?.users ?? []
        )
    }
}

private struct AddressList: Decodable { var addresses: [AdminAddress] }

private struct AliasesList: View {
    let panel: AdminPanel
    @State private var list: [AdminAddress]?
    @State private var directory = Directory()
    @State private var editing: AddressDraft?
    @State private var deleting: AdminAddress?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Aliases deliver to one mailbox and can be used as a From address. Groups deliver to several people, including outside addresses.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("New Group…") { editing = AddressDraft(kind: "group") }
                Button("New Alias…") { editing = AddressDraft(kind: "alias") }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if let list, list.isEmpty {
                ContentUnavailableView("No Aliases or Groups", systemImage: "at", description: Text("Make addresses like hello@, support@ or team@ that reach your people."))
            } else {
                List(list ?? []) { a in row(a) }
            }
        }
        .task(id: panel.generation) {
            list = await panel.fetch("/addresses", as: AddressList.self)?.addresses
            directory = await Directory.load(panel)
        }
        .sheet(item: $editing) { draft in AddressSheet(panel: panel, directory: directory, draft: draft) }
        .confirmationDialog("Delete \(deleting?.address ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { a in
            Button("Delete", role: .destructive) { panel.change("DELETE", "/addresses/\(a.id)") { _ in (text: "\(a.address) deleted.", link: nil) } }
        } message: { _ in
            Text("Mail to it will be refused.")
        }
    }

    private func row(_ a: AdminAddress) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.address).fontWeight(.medium)
                    AdminBadge(text: a.isGroup ? "Group" : "Alias", tone: a.isGroup ? .accent : .plain)
                    if !a.enabled { AdminBadge(text: "Disabled", tone: .warn) }
                    if a.canSend { AdminBadge(text: "Can send as", tone: .ok) }
                }
                if let label = [a.name, a.description ?? ""].first(where: { !$0.isEmpty }) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                Text(a.isGroup ? a.members.map(\.address).joined(separator: ", ") : "→ \(a.userEmail ?? "nobody")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Edit…") { editing = AddressDraft(a) }
            Button { deleting = a } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(a.address)")
        }
        .padding(.vertical, 2)
    }
}

/// An alias or group being made or changed.
private struct AddressDraft: Identifiable {
    var id: String
    var existing: Int?
    var kind: String
    var local = ""
    var domain = ""
    var name = ""
    var userId: Int?
    var members = ""
    var canSend = true
    var enabled = true
    var description = ""

    init(kind: String) {
        id = "new \(kind)"
        self.kind = kind
    }

    init(_ a: AdminAddress) {
        id = "\(a.id)"
        existing = a.id
        kind = a.kind
        let parts = a.address.split(separator: "@", maxSplits: 1).map(String.init)
        local = parts.first ?? ""
        domain = parts.count > 1 ? parts[1] : ""
        name = a.name
        userId = a.userId
        members = a.members.map(\.address).joined(separator: "\n")
        canSend = a.canSend
        enabled = a.enabled
        description = a.description ?? ""
    }

    var memberList: [String] {
        members.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private struct AddressSheet: View {
    let panel: AdminPanel
    let directory: Directory
    @State var draft: AddressDraft
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    private var isGroup: Bool { draft.kind == "group" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.existing == nil ? (isGroup ? "New Group" : "New Alias") : "Edit \(draft.local)@\(draft.domain)").font(.headline)
            Form {
                if draft.existing == nil {
                    HStack {
                        TextField("Address", text: $draft.local, prompt: Text(isGroup ? "team" : "hello"))
                        Text("@")
                        Picker("Domain", selection: $draft.domain) {
                            ForEach(directory.domains) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                TextField("Display name", text: $draft.name, prompt: Text(isGroup ? "Design Team" : ""))
                if isGroup {
                    TextField("Members", text: $draft.members, prompt: Text("One address per line"), axis: .vertical)
                        .lineLimit(4...10)
                    Text("People here get mail directly; outside addresses get a forwarded copy.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Delivers to", selection: $draft.userId) {
                        Text("Choose a mailbox…").tag(Int?.none)
                        ForEach(directory.people) { u in Text(u.name.isEmpty ? u.email : "\(u.name) <\(u.email)>").tag(Optional(u.id)) }
                    }
                }
                Toggle("Allow sending as this address", isOn: $draft.canSend)
                Text(isGroup ? "Members can choose it as their From address." : "The mailbox owner can choose it as their From address.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enabled", isOn: $draft.enabled)
                TextField("Note", text: $draft.description, prompt: Text("For other admins (optional)"))
            }
            SheetButtons(error: error, busy: busy, action: "Save", disabled: !ready, cancel: { dismiss() }, perform: save)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { if draft.domain.isEmpty { draft.domain = directory.domains.first?.name ?? "" } }
    }

    private var ready: Bool {
        (draft.existing != nil || (!draft.local.isEmpty && !draft.domain.isEmpty)) && (isGroup ? !draft.memberList.isEmpty : draft.userId != nil)
    }

    private func save() {
        var body: [String: JSON] = [
            "name": .string(draft.name),
            "canSend": .bool(draft.canSend),
            "enabled": .bool(draft.enabled),
            "description": .string(draft.description),
        ]
        if isGroup { body["members"] = .array(draft.memberList.map(JSON.string)) }
        if !isGroup, let id = draft.userId { body["userId"] = .number(Double(id)) }
        let isNew = draft.existing == nil
        if isNew {
            body["address"] = .string("\(draft.local.lowercased())@\(draft.domain)")
            body["kind"] = .string(draft.kind)
            if isGroup { body["userId"] = .null } else { body["members"] = [] }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let id = draft.existing {
                    try await panel.send("PUT", "/addresses/\(id)", .object(body))
                } else {
                    try await panel.send("POST", "/addresses", .object(body))
                }
                panel.notice = (text: isNew ? "\(draft.local.lowercased())@\(draft.domain) created." : "Saved.", link: nil)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: Shared mailboxes

private struct SharedMailboxes: Decodable { var mailboxes: [AdminSharedMailbox] }

private struct SharedList: View {
    let panel: AdminPanel
    @State private var list: [AdminSharedMailbox]?
    @State private var directory = Directory()
    @State private var editing: SharedDraft?
    @State private var deleting: AdminSharedMailbox?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inboxes a team reads together, like support@. Members switch to them from the mail sidebar; replies go out from the shared address.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("New Shared Mailbox…") { editing = SharedDraft() }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if let list, list.isEmpty {
                ContentUnavailableView("No Shared Mailboxes", systemImage: "tray.2", description: Text("Make one for an address a team answers together. Unlike a group, everyone sees the same conversations and who replied."))
            } else {
                List(list ?? []) { b in row(b) }
            }
        }
        .task(id: panel.generation) {
            list = await panel.fetch("/shared-mailboxes", as: SharedMailboxes.self)?.mailboxes
            directory = await Directory.load(panel)
        }
        .sheet(item: $editing) { draft in SharedSheet(panel: panel, directory: directory, draft: draft) }
        .sheet(item: $deleting) { b in
            TypedConfirmSheet(
                title: "Delete \(b.address)?",
                message: "This deletes the shared mailbox and all of its mail. It can’t be undone.",
                phrase: b.address,
                action: "Delete Mailbox"
            ) {
                try await panel.send("DELETE", "/shared-mailboxes/\(b.id)")
                panel.notice = (text: "\(b.address) deleted.", link: nil)
            }
        }
    }

    private func row(_ b: AdminSharedMailbox) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(b.address).fontWeight(.medium)
                    if b.status == "suspended" { AdminBadge(text: "Paused", tone: .warn) }
                    if let n = b.unread, n > 0 { AdminBadge(text: "\(n) unread", tone: .accent) }
                }
                Text(b.name).font(.caption).foregroundStyle(.secondary)
                Text(b.members.isEmpty ? "No members yet" : b.members.map { "\($0.email)\($0.canSend ? "" : " (read only)")" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(b.members.isEmpty ? Color.orange : Color.secondary).lineLimit(2)
                Text("\(adminBytes(b.usedBytes)) of \(adminBytes(b.quotaBytes))").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Edit…") { editing = SharedDraft(b) }
            Button { deleting = b } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(b.address)")
        }
        .padding(.vertical, 2)
    }
}

private struct SharedDraft: Identifiable {
    var id = "new"
    var existing: Int?
    var local = ""
    var domain = ""
    var name = ""
    var quota = ""
    var active = true
    /// Member ids, and whether each can send.
    var members: [Int: Bool] = [:]

    init() {}

    init(_ b: AdminSharedMailbox) {
        id = "\(b.id)"
        existing = b.id
        let parts = b.address.split(separator: "@", maxSplits: 1).map(String.init)
        local = parts.first ?? ""
        domain = parts.count > 1 ? parts[1] : ""
        name = b.name
        active = b.status != "suspended"
        members = Dictionary(b.members.map { ($0.userId, $0.canSend) }, uniquingKeysWith: { a, _ in a })
    }
}

private struct SharedSheet: View {
    let panel: AdminPanel
    let directory: Directory
    @State var draft: SharedDraft
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var busy = false
    @State private var error: String?

    private var people: [AdminUser] {
        let f = filter.lowercased()
        return directory.people.filter { f.isEmpty || "\($0.name) \($0.email)".lowercased().contains(f) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.existing == nil ? "New Shared Mailbox" : "Edit \(draft.local)@\(draft.domain)").font(.headline)
            Form {
                if draft.existing == nil {
                    HStack {
                        TextField("Address", text: $draft.local, prompt: Text("support"))
                        Text("@")
                        Picker("Domain", selection: $draft.domain) {
                            ForEach(directory.domains) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                TextField("Display name", text: $draft.name, prompt: Text("Support team"))
                TextField("Quota (MB)", text: $draft.quota, prompt: Text(draft.existing == nil ? "Default" : "Keep the current quota"))
                if draft.existing != nil {
                    Toggle("Receiving mail", isOn: $draft.active)
                    Text("Paused mailboxes refuse new mail; members can still read what’s there.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Members (\(draft.members.count))") {
                    if directory.people.count > 8 { TextField("Find people", text: $filter) }
                    ForEach(people) { u in member(u) }
                }
            }
            .formStyle(.grouped)
            SheetButtons(error: error, busy: busy, action: draft.existing == nil ? "Create" : "Save", disabled: draft.name.trimmingCharacters(in: .whitespaces).isEmpty || (draft.existing == nil && draft.local.isEmpty), cancel: { dismiss() }, perform: save)
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .onAppear { if draft.domain.isEmpty { draft.domain = directory.domains.first?.name ?? "" } }
    }

    private func member(_ u: AdminUser) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { draft.members[u.id] != nil }, set: { draft.members[u.id] = $0 ? true : nil })) {
                VStack(alignment: .leading) {
                    Text(u.name.isEmpty ? u.email : u.name)
                    if !u.name.isEmpty { Text(u.email).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let canSend = draft.members[u.id] {
                Picker("Access for \(u.email)", selection: Binding(get: { canSend }, set: { draft.members[u.id] = $0 })) {
                    Text("Read and send").tag(true)
                    Text("Read only").tag(false)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func save() {
        let q = draft.quota.trimmingCharacters(in: .whitespaces)
        guard q.isEmpty || Int(q) != nil else {
            error = "Enter the quota in whole megabytes."
            return
        }
        let members: JSON = .array(draft.members.sorted { $0.key < $1.key }.map { ["userId": .number(Double($0.key)), "canSend": .bool($0.value)] })
        var body: [String: JSON] = ["name": .string(draft.name.trimmingCharacters(in: .whitespaces)), "members": members]
        if let mb = Int(q) { body["quotaMb"] = .number(Double(mb)) }
        let isNew = draft.existing == nil
        if isNew {
            body["address"] = .string("\(draft.local.lowercased())@\(draft.domain)")
            if body["quotaMb"] == nil { body["quotaMb"] = .null }
        } else {
            body["status"] = .string(draft.active ? "active" : "suspended")
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let id = draft.existing {
                    try await panel.send("PUT", "/shared-mailboxes/\(id)", .object(body))
                } else {
                    try await panel.send("POST", "/shared-mailboxes", .object(body))
                }
                panel.notice = (text: isNew ? "Shared mailbox created." : "Saved.", link: nil)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
