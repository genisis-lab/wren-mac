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
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag("account")
            OutOfOfficeSettings()
                .tabItem { Label("Out of Office", systemImage: "airplane") }
                .tag("vacation")
            ViewingSettings()
                .tabItem { Label("Viewing", systemImage: "eye") }
                .tag("viewing")
        }
        .frame(width: 460)
    }
}

struct GeneralSettings: View {
    @State private var current = GeneralSettings.defaultApp

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
                            // Only an app bundle can be one (not a bare `swift run` binary).
                            .disabled(Bundle.main.bundleIdentifier == nil)
                    }
                }
            }
            Text("Email links in other apps and on the web open a new message in your default email app.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

struct AccountSettings: View {
    @Environment(MailStore.self) private var store
    @State private var confirming = false

    var body: some View {
        Form {
            if let client = store.client {
                LabeledContent("Signed in as", value: client.username)
                LabeledContent("Server", value: client.server.absoluteString)
                if let quota = store.quota {
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
                if store.accounts.count > 1 {
                    LabeledContent("Shared mailboxes") {
                        Text(store.accounts.filter { !$0.isPersonal }.map(\.name).joined(separator: "\n"))
                            .multilineTextAlignment(.trailing)
                    }
                }
                Button("Sign Out…", role: .destructive) { confirming = true }
            } else {
                Text("Not signed in.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Sign out of Wren?", isPresented: $confirming) {
            Button("Sign Out", role: .destructive) { store.signOut() }
        } message: {
            Text("The app password is removed from this Mac. Your mail stays on the server; drafts you haven’t saved are lost.")
        }
    }
}

/// The automatic reply Wren sends while you're away.
struct OutOfOfficeSettings: View {
    @Environment(MailStore.self) private var store
    /// As on the server, to tell what changed.
    @State private var saved: VacationResponse?
    @State private var reply = VacationResponse()
    @State private var unavailable = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
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
        .task(id: store.personalAccount) { await load() }
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

    private func load() async {
        guard let personal = store.personalAccount else { return }
        unavailable = !personal.capabilities.contains(Capability.vacation)
        do {
            guard let current = try await store.vacation() else { return }
            saved = current
            reply = current
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard let old = saved else { return }
        busy = true
        Task {
            do {
                try await store.saveVacation(reply, was: old)
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
