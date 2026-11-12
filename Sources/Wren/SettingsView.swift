import AppKit
import SwiftUI
import WrenKit

struct SettingsView: View {
    /// Opens on the tab last used, as Mac apps do (and lets the screenshot run pick one).
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            AccountSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag("account")
            OutOfOfficeSettings()
                .tabItem { Label("Out of Office", systemImage: "airplane") }
                .tag("vacation")
            ViewingSettings()
                .tabItem { Label("Viewing", systemImage: "eye") }
                .tag("viewing")
            EncryptionSettings()
                .tabItem { Label("Encryption", systemImage: "lock") }
                .tag("encryption")
        }
        .frame(width: 460)
    }
}

struct GeneralSettings: View {
    @State private var current = GeneralSettings.defaultApp
    @AppStorage("undoSendSeconds") private var undoSendSeconds = 10
    private let updates = Updates.shared

    /// The app that opens mailto: links now.
    private static var defaultApp: URL? {
        URL(string: "mailto:").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    private var isWren: Bool { current?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }

    var body: some View {
        Form {
            LabeledContent("Default email app") {
                if isWren {
                    Text("Wren")
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let current { Text(FileManager.default.displayName(atPath: current.path)).foregroundStyle(.secondary) }
                        Button("Make Wren the Default") { makeDefault() }
                    }
                }
            }
            Text("Email links in other apps and on the web open a new message in your default email app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Section("Writing") {
                Picker("Undo Send", selection: $undoSendSeconds) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Text("After you click Send, the message waits this long, so Edit → Undo Send (⌘Z) can stop it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.setAutomaticallyChecks($0) }
                ))
                .disabled(!updates.isConfigured)
                Text("Checks GitHub hourly while Wren is running. You choose when to install an update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func makeDefault() {
        Task {
            // macOS asks the person to confirm.
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
            current = GeneralSettings.defaultApp
        }
    }
}

/// Each Wren sign-in, with its storage and shared mailboxes; add another or remove one.
struct AccountSettings: View {
    @Environment(MailStore.self) private var store
    @State private var adding = false
    @State private var removing: Login?

    var body: some View {
        Form {
            ForEach(store.logins) { login in
                Section(login.username) {
                    LabeledContent("Server", value: login.client.server.absoluteString)
                    if let quota = login.quota {
                        LabeledContent("Storage") {
                            VStack(alignment: .trailing, spacing: 4) {
                                if quota.hardLimit > 0 {
                                    ProgressView(value: quota.fraction)
                                        .tint(quota.fraction >= 0.9 ? .red : nil)
                                        .frame(width: 160)
                                }
                                Text(storageText(quota)).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityValue(storageText(quota))
                    }
                    let shared = login.accounts.filter { !$0.isPersonal }
                    if !shared.isEmpty {
                        LabeledContent("Shared mailboxes") {
                            Text(shared.map(\.name).joined(separator: "\n"))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Button("Remove Account…", role: .destructive) { removing = login }
                }
            }
            Button("Add Account…") { adding = true }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $adding) {
            SignInView { adding = false }
                .frame(width: 500, height: 520)
        }
        .confirmationDialog(
            "Remove \(removing?.username ?? "this account")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { login in
            Button("Remove", role: .destructive) { store.remove(login) }
        } message: { _ in
            Text("Its app password and the mail kept on this Mac are removed. The mail stays on the server; drafts you haven’t saved are lost.")
        }
    }
}

/// The automatic reply Wren sends while you're away, for one sign-in at a time.
struct OutOfOfficeSettings: View {
    @Environment(MailStore.self) private var store
    @State private var loginId: String?
    /// As on the server, to tell what changed.
    @State private var saved: VacationResponse?
    @State private var reply = VacationResponse()
    @State private var unavailable = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let login = store.login(loginId) ?? store.logins.first
        Form {
            if store.logins.count > 1 {
                Picker("Account", selection: Binding(get: { login?.id }, set: { loginId = $0 })) {
                    ForEach(store.logins) { Text($0.username).tag(Optional($0.id)) }
                }
            }
            if unavailable {
                Text("Your Wren server doesn’t offer automatic replies to mail apps.").foregroundStyle(.secondary)
            } else {
                Toggle("Send an automatic reply", isOn: $reply.isEnabled)
                Section {
                    dateRow("Starting", \.fromDate)
                    dateRow("Ending", \.toDate)
                    TextField("Subject", text: Binding(get: { reply.subject ?? "" }, set: { reply.subject = $0 }), prompt: Text("Out of office"))
                    TextEditor(text: Binding(get: { reply.textBody ?? "" }, set: { reply.textBody = $0 }))
                        .font(.body)
                        .frame(height: 110)
                        .accessibilityLabel("Message")
                }
                .disabled(!reply.isEnabled)
                HStack {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || saved == nil || reply == saved)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(busy)
        .task(id: "\(login?.id ?? "") \(login?.personal?.id ?? "")") { await load(login) }
    }

    /// A date that's optional: off means "from now" or "until I turn it off".
    private func dateRow(_ title: String, _ key: WritableKeyPath<VacationResponse, Date?>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { reply[keyPath: key] != nil }, set: { reply[keyPath: key] = $0 ? Calendar.current.startOfDay(for: .now) : nil }))
                .toggleStyle(.checkbox)
            Spacer()
            if let date = reply[keyPath: key] {
                DatePicker(title, selection: Binding(get: { date }, set: { reply[keyPath: key] = $0 }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
        }
    }

    private func load(_ login: Login?) async {
        saved = nil
        reply = VacationResponse()
        error = nil
        guard let login, let personal = login.personal else { return }
        unavailable = !personal.capabilities.contains(Capability.vacation)
        do {
            guard let current = try await store.vacation(login) else { return }
            saved = current
            reply = current
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard let old = saved, let login = store.login(loginId) ?? store.logins.first else { return }
        busy = true
        Task {
            do {
                try await store.saveVacation(reply, was: old, in: login)
                saved = reply
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct ViewingSettings: View {
    @AppStorage("loadRemoteContent") private var loadRemoteContent = false

    var body: some View {
        Form {
            Toggle("Load remote content in messages", isOn: $loadRemoteContent)
            Text("Remote images and fonts can tell a sender when you opened their message and roughly where you are. When this is off, each message has a button to load them. Pictures that only track you are never loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Each sign-in's PGP key, restored from the backup made in Wren on the web, as the web app keeps it: protected by
/// its passphrase in the keychain, and unlocked only until Wren quits.
struct EncryptionSettings: View {
    @Environment(MailStore.self) private var store
    @State private var keys: [String: PGP.KeyInfo] = [:]
    @State private var busy: String?
    @State private var problem: String?

    var body: some View {
        Form {
            ForEach(store.logins) { login in
                Section(login.username) {
                    if let key = keys[login.id] {
                        let open = PGP.shared.unlocked.contains(login.id)
                        LabeledContent("Key", value: key.userIds.joined(separator: ", "))
                        LabeledContent("Fingerprint") {
                            Text(key.groupedFingerprint)
                                .font(.system(.callout, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Status", value: open ? "Unlocked until you quit Wren" : "Locked")
                        HStack {
                            Spacer()
                            if open {
                                Button("Lock") { store.lockPGP(login) }
                            } else {
                                Button("Unlock…") { Task { _ = await PGP.shared.unlockAsking(login) } }
                            }
                            Button("Remove from This Mac") {
                                PGP.shared.forget(login)
                                store.decrypted = [:]
                                keys[login.id] = nil
                            }
                            .help("The backup in Wren stays, so you can restore it again.")
                        }
                    } else if login.personal?.hasWren == true {
                        Text("Restore the PGP key you backed up in Wren on the web, to read encrypted mail and to encrypt and sign what you send. Your passphrase unlocks it on this Mac and is never saved.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            if busy == login.id { ProgressView().controlSize(.small) }
                            Button("Restore from Wren…") { restore(login) }
                                .disabled(busy != nil)
                        }
                    } else {
                        Text("This server doesn’t offer PGP keys to mail apps.").foregroundStyle(.secondary)
                    }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: store.logins.map(\.id)) {
            for login in store.logins { keys[login.id] = await PGP.shared.key(login) }
        }
    }

    private func restore(_ login: Login) {
        guard let passphrase = PGP.askPassphrase(
            title: "Restore Your PGP Key", message: "Enter the passphrase you chose when you backed up your key in Wren.", button: "Restore"
        ) else { return }
        busy = login.id
        problem = nil
        Task {
            do {
                keys[login.id] = try await PGP.shared.restore(login, passphrase: passphrase)
            } catch {
                problem = error.localizedDescription
            }
            busy = nil
        }
    }
}
