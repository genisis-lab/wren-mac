import AppKit
import SwiftUI
import WrenKit

/// Your name, signatures and the address new mail is from: Wren's own settings, the same ones as in Settings on the
/// web, for one sign-in at a time. Saving sends only what changed, so a change made meanwhile on the web stays.
struct SignatureSettings: View {
    @Environment(MailStore.self) private var store
    @State private var loginId: String?
    /// As on the server, to tell what changed.
    @State private var saved: Preferences?
    @State private var prefs = Preferences()
    @State private var savedName = ""
    @State private var name = ""
    /// The signature being edited: "" for the default one, else one of your addresses (lower-cased).
    @State private var editing = ""
    /// Starts the editor over (another address, or what the server has after saving).
    @State private var editorVersion = 0
    @State private var format = FormatState()
    @State private var editor = EditorController()
    @State private var unavailable = false
    @State private var busy = false
    @State private var error: String?
    @State private var savedNote = false

    var body: some View {
        let login = store.login(loginId) ?? store.logins.first
        Form {
            if store.logins.count > 1 {
                Picker("Account", selection: Binding(get: { login?.id }, set: { loginId = $0 })) {
                    ForEach(store.logins) { Text($0.username).tag(Optional($0.id)) }
                }
            }
            if unavailable {
                Text("Your Wren server doesn’t share these settings with mail apps. Change them in Settings on the web.")
                    .foregroundStyle(.secondary)
            } else if let login, saved != nil {
                nameSection(login)
                signatureSection(login)
                saveRow(login)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: "\(login?.id ?? "") \(login?.personal?.id ?? "")") { await load(login) }
    }

    /// Your name, and which of your addresses new messages are from.
    private func nameSection(_ login: Login) -> some View {
        let identities = Self.identities(login)
        let mailbox = Self.mailbox(login)
        return Section {
            TextField("Your name", text: $name, prompt: Text(mailbox?.email ?? ""))
            if identities.count > 1 {
                Picker("New messages from", selection: Binding(
                    get: { Self.tag(prefs.defaultFrom, mailbox: mailbox, among: identities) },
                    set: { prefs.defaultFrom = $0 }
                )) {
                    ForEach(identities) { identity in
                        Text(identity.email).tag(Self.tag(identity.email, mailbox: mailbox, among: identities))
                    }
                }
            }
        } footer: {
            if identities.count > 1 {
                Text("Other addresses’ names are set by your administrator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The signature for all addresses or for one, in the same editor as messages.
    private func signatureSection(_ login: Login) -> some View {
        let identities = Self.identities(login)
        return Section("Signature") {
            if identities.count > 1 {
                Picker("For", selection: $editing) {
                    Text("All addresses").tag("")
                    ForEach(identities) { identity in
                        let own = prefs.signatures[identity.email.lowercased()] != nil
                        Text(own ? "\(identity.email) ✓" : identity.email).tag(identity.email.lowercased())
                    }
                }
            }
            VStack(spacing: 0) {
                FormatBar(state: format, editor: editor)
                Divider()
                RichEditor(
                    html: current, startFocused: false, controller: editor, state: $format,
                    onChange: { setCurrent($0) }, onFiles: { _ in }
                )
                .id("\(login.id) \(editing) \(editorVersion)")
                .frame(height: 130)
                .accessibilityLabel(editing.isEmpty ? "Signature" : "Signature for \(editing)")
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            if !editing.isEmpty && prefs.signatures[editing] == nil {
                Text("This address uses the signature for all addresses until you write one for it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Add the signature to replies and forwards", isOn: $prefs.signatureOnReplies)
        }
    }

    private func saveRow(_ login: Login) -> some View {
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if savedNote {
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Save") { save(login) }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !changed)
        }
    }

    private var changed: Bool {
        guard let saved else { return false }
        let n = name.trimmingCharacters(in: .whitespaces)
        return prefs != saved || (!n.isEmpty && n != savedName)
    }

    /// The signature being edited, as HTML.
    private var current: String {
        editing.isEmpty ? prefs.signature : prefs.signatures[editing] ?? ""
    }

    private func setCurrent(_ html: String) {
        savedNote = false
        if editing.isEmpty {
            prefs.signature = Preferences.isBlank(html) ? "" : html
        } else {
            prefs.setSignature(html, for: editing)
        }
    }

    /// A sign-in's own addresses, its mailbox first.
    private static func identities(_ login: Login) -> [Identity] {
        guard let personal = login.personal else { return [] }
        let all = login.identities[personal.id] ?? []
        let own = mailbox(login)
        return all.filter { $0.id == own?.id } + all.filter { $0.id != own?.id }
    }

    /// The mailbox's own address (the one signed in with): the only one whose name you set yourself.
    private static func mailbox(_ login: Login) -> Identity? {
        guard let personal = login.personal else { return nil }
        let all = login.identities[personal.id] ?? []
        return all.first { $0.email.lowercased() == login.username.lowercased() } ?? all.first
    }

    /// The picker's tag for an address: "" for the mailbox's own (Wren's "no choice"), else the address.
    private static func tag(_ address: String, mailbox: Identity?, among identities: [Identity]) -> String {
        let a = address.lowercased()
        guard !a.isEmpty, a != mailbox?.email.lowercased(), identities.contains(where: { $0.email.lowercased() == a }) else { return "" }
        return a
    }

    private func load(_ login: Login?) async {
        saved = nil
        error = nil
        editing = ""
        savedNote = false
        guard let login, let personal = login.personal else { return }
        unavailable = personal.hasPreferences != true
        savedName = Self.mailbox(login)?.name ?? ""
        name = savedName
        guard !unavailable else { return }
        do {
            guard let current = try await store.preferences(login) else { return }
            saved = current
            prefs = current
            editorVersion += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ login: Login) {
        guard let old = saved else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let newName = trimmed != savedName && !trimmed.isEmpty ? trimmed : nil
        busy = true
        error = nil
        Task {
            do {
                try await store.savePreferences(prefs, was: old, name: newName, in: login)
                // What the server has now, which may include changes made meanwhile on the web.
                let now = login.preferences ?? prefs
                if now != prefs { editorVersion += 1 }
                saved = now
                prefs = now
                savedName = Self.mailbox(login)?.name ?? trimmed
                name = savedName
                savedNote = true
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
