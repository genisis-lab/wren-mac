import AppKit
import SwiftUI
import WrenKit

/// The tabs of Settings & Policies, named as in the web's links (/admin/settings/security).
enum AdminSettingsTab: String, CaseIterable, Identifiable {
    case general, registration, security, limits, spam, alerts, retention
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .registration: "Registration"
        case .security: "Security"
        case .limits: "Limits"
        case .spam: "Spam & Blocking"
        case .alerts: "Alerts"
        case .retention: "Retention"
        }
    }
}

/// Admin → Settings & Policies: the server's own settings. Changes wait until Save, and only the ones you
/// made are sent, so two admins changing different settings don't undo each other.
struct AdminSettingsPage: View {
    @Bindable var panel: AdminPanel
    @State private var loaded: AdminSettings?
    @State private var draft: [String: JSON] = [:]
    @State private var domains: [AdminDomain] = []
    @State private var addresses: [String] = []
    @State private var blocked: [AdminBlocked] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $panel.settingsTab) {
                ForEach(AdminSettingsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(10)
            if let loaded {
                Form { tab(loaded) }
                    .formStyle(.grouped)
                if !changes.isEmpty || error != nil { saveBar }
            } else {
                AdminLoading()
            }
        }
        .task(id: panel.generation) { await load() }
    }

    private var changes: [String: JSON] {
        loaded.map { AdminSettings.changes(draft, from: $0.settings) } ?? [:]
    }

    private var binder: SettingsBinder { SettingsBinder(draft: $draft) }

    /// Loads again, keeping changes not saved yet (another change on the page, such as the blocklist, reloads it).
    private func load() async {
        let pending = changes
        guard let s = await panel.fetch("/settings", as: AdminSettings.self) else { return }
        loaded = s
        draft = s.settings.merging(pending) { $1 }
        domains = await panel.fetch("/domains", as: DomainList.self)?.domains ?? []
        addresses = await panel.fetch("/addresses", as: Addresses.self)?.addresses.map(\.address) ?? []
        blocked = await panel.fetch("/blocklist", as: Blocked.self)?.items ?? []
    }

    @ViewBuilder private func tab(_ s: AdminSettings) -> some View {
        switch panel.settingsTab {
        case .general: GeneralSettings(panel: panel, s: binder, sender: s.systemSender, domains: domains, addresses: addresses)
        case .registration: RegistrationSettings(s: binder, domains: domains)
        case .security: SecuritySettings(s: binder, clientIp: s.clientIp)
        case .limits: LimitsSettings(s: binder)
        case .spam: SpamSettings(panel: panel, s: binder, defaults: s.defaults, blocked: blocked)
        case .alerts: AlertSettings(s: binder)
        case .retention: RetentionSettings(s: binder)
        }
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(changes.count == 1 ? "1 unsaved change" : "\(changes.count) unsaved changes").foregroundStyle(.secondary)
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Discard") {
                    error = nil
                    if let loaded { draft = loaded.settings }
                }
                .disabled(changes.isEmpty || saving)
                Button("Save Changes") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(changes.isEmpty || saving)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func save() {
        let changed = changes
        guard !changed.isEmpty else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await panel.send("PUT", "/settings", .object(changed))
                // Saved: nothing is pending now, so the reload that follows takes the server's values as they are.
                loaded?.settings = draft
                panel.notice = (text: "Settings saved.", link: nil)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private struct Addresses: Decodable { var addresses: [AdminAddress] }
    private struct Blocked: Decodable { var items: [AdminBlocked] }
}

/// Bindings to one setting each, by key.
struct SettingsBinder {
    let draft: Binding<[String: JSON]>

    subscript(key: String) -> JSON? { draft.wrappedValue[key] }

    func set(_ key: String, _ value: JSON) { draft.wrappedValue[key] = value }

    func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { draft.wrappedValue[key]?.bool ?? false }, set: { draft.wrappedValue[key] = .bool($0) })
    }

    func text(_ key: String) -> Binding<String> {
        Binding(get: { draft.wrappedValue[key]?.string ?? "" }, set: { draft.wrappedValue[key] = .string($0) })
    }

    func int(_ key: String) -> Binding<Int> {
        Binding(get: { Int(draft.wrappedValue[key]?.number ?? 0) }, set: { draft.wrappedValue[key] = .number(Double($0)) })
    }

    func double(_ key: String) -> Binding<Double> {
        Binding(get: { draft.wrappedValue[key]?.number ?? 0 }, set: { draft.wrappedValue[key] = .number($0) })
    }

    /// A saved secret comes back masked: it shows empty, and stays as it is unless a new one is typed.
    func secret(_ key: String) -> Binding<String> {
        let mask = "••••••••"
        return Binding(get: { draft.wrappedValue[key]?.string == mask ? "" : draft.wrappedValue[key]?.string ?? "" }, set: { new in
            draft.wrappedValue[key] = .string(new.isEmpty && draft.wrappedValue[key]?.string == mask ? mask : new)
        })
    }

    func isMasked(_ key: String) -> Bool { draft.wrappedValue[key]?.string == "••••••••" }
}

/// A number setting, with what it means underneath.
private struct NumberRow: View {
    let title: String
    @Binding var value: Int
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) {
                TextField(title, value: $value, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
            if let help { SettingHelp(help) }
        }
    }
}

/// A switch, with what it does underneath.
private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: $isOn)
            if let help { SettingHelp(help) }
        }
    }
}

private struct SettingHelp: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralSettings: View {
    let panel: AdminPanel
    let s: SettingsBinder
    let sender: AdminSettings.Sender?
    let domains: [AdminDomain]
    let addresses: [String]

    private static let swatches = ["#2563eb", "#0f766e", "#7c3aed", "#db2777", "#ea580c", "#16a34a", "#0f172a"]

    var body: some View {
        Section("Branding") {
            TextField("Instance name", text: s.text("instance.name"))
            LabeledContent("Accent colour") {
                HStack(spacing: 8) {
                    ColorPicker("Accent colour", selection: accent, supportsOpacity: false).labelsHidden()
                    TextField("Hex", text: s.text("instance.accent"))
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                        .frame(width: 90)
                    ForEach(Self.swatches, id: \.self) { c in
                        Button { s.set("instance.accent", .string(c)) } label: {
                            Circle().fill(Self.color(c)).frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign-in page message")
                TextEditor(text: s.text("instance.loginMessage")).frame(minHeight: 54)
                SettingHelp("Shown above the sign-in form, for example how to reach support.")
            }
        }
        Section {
            if let sender { LabeledContent("Sent as", value: "\(sender.name) <\(sender.address)>") }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Send from", text: s.text("mail.systemFrom"), prompt: Text("contact@\(firstDomain)"))
                    if !suggestions.isEmpty {
                        Menu("Choose") {
                            ForEach(suggestions, id: \.self) { a in Button(a) { s.set("mail.systemFrom", .string(a)) } }
                        }
                        .fixedSize()
                    }
                }
                SettingHelp("An address on a domain hosted here, so your provider can send it. To send from a subdomain such as contact.\(firstDomain), add it under Domains and verify it first. Blank: contact@\(firstDomain).")
                if let d = senderDomain { SenderStatus(panel: panel, domain: d) }
            }
            VStack(alignment: .leading, spacing: 3) {
                TextField("Sender name", text: s.text("mail.systemName"), prompt: Text(s["instance.name"]?.string ?? ""))
                SettingHelp("Blank: the instance name.")
            }
            VStack(alignment: .leading, spacing: 3) {
                TextField("Replies go to", text: s.text("mail.systemReplyTo"), prompt: Text("No Reply-To"))
                SettingHelp("Optional. Replies to a system email go here (support@, say). Blank: to the Send from address.")
            }
        } header: {
            Text("System emails")
        } footer: {
            Text("Everything Wren sends by itself: invitations, setup and password links, welcome messages, recovery-email confirmations, sign-in alerts, admin alerts and announcements.")
        }
    }

    private var enabled: [String] { domains.filter(\.enabled).map(\.name) }
    private var firstDomain: String { enabled.first ?? "yourdomain.com" }

    /// The usual sender names on each hosted domain, then the addresses that already exist.
    private var suggestions: [String] {
        var seen = Set<String>()
        return (enabled.flatMap { ["contact@\($0)", "no-reply@\($0)"] } + addresses).filter { seen.insert($0).inserted }
    }

    private var senderDomain: String? {
        let typed = (s["mail.systemFrom"]?.string ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let at = typed.lastIndex(of: "@"), typed[typed.index(after: at)...].contains(".") { return String(typed[typed.index(after: at)...]) }
        return sender?.address.split(separator: "@").last.map(String.init)
    }

    private var accent: Binding<Color> {
        Binding(get: { Self.color(s["instance.accent"]?.string ?? "") }, set: { s.set("instance.accent", .string(Self.hex($0))) })
    }

    static func color(_ hex: String) -> Color {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return .accentColor }
        return Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#2563eb" }
        let byte = { (x: CGFloat) in Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

// MARK: Registration

private struct RegistrationSettings: View {
    let s: SettingsBinder
    let domains: [AdminDomain]

    var body: some View {
        Section("New accounts") {
            ToggleRow(title: "Send a welcome message", isOn: s.bool("users.welcomeMessage"), help: "New mailboxes start with a short message: their address, what to set up first, importing old mail and installing the app.")
            ToggleRow(title: "Let people create their own aliases", isOn: s.bool("aliases.selfService"), help: "In Settings → Accounts, on their own domain. Reserved names like postmaster@ and admin@ stay off limits.")
            if s["aliases.selfService"]?.bool == true {
                NumberRow(title: "Aliases per person", value: s.int("aliases.maxPerUser"))
            }
            ToggleRow(title: "Let people make throwaway sign-up addresses", isOn: s.bool("aliases.throwaway"), help: "One per site, which they can turn off when it starts getting spam. Administrators can always make them.")
            if s["aliases.throwaway"]?.bool == true {
                NumberRow(title: "Sign-up addresses per person", value: s.int("aliases.maxThrowaway"))
            }
        }
        Section("Who can create accounts?") {
            Picker("Who can create accounts?", selection: s.text("registration.mode")) {
                Text("Closed: only administrators create accounts").tag("closed")
                Text("Invite only: people with an invitation link can sign up").tag("invite")
                Text("Open: anyone can sign up on the domains you choose").tag("open")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if s["registration.mode"]?.string == "open" {
                SettingHelp("Consider requiring 2-step sign-in and lowering send limits.")
            }
        }
        if s["registration.mode"]?.string == "open" {
            Section("Domains open for sign-up") {
                ForEach(domains) { d in
                    Toggle(d.name, isOn: allows(d.id))
                }
            }
        }
    }

    private func allows(_ id: Int) -> Binding<Bool> {
        let ids = { (s["registration.domains"]?.array ?? []).compactMap(\.int) }
        return Binding(get: { ids().contains(id) }, set: { on in
            let new = on ? ids() + [id] : ids().filter { $0 != id }
            s.set("registration.domains", .array(new.map { JSON.number(Double($0)) }))
        })
    }
}

// MARK: Security

private struct SecuritySettings: View {
    let s: SettingsBinder
    let clientIp: String?

    var body: some View {
        Section("Security policies") {
            Picker("Require 2-step sign-in for", selection: s.text("security.require2fa")) {
                Text("Nobody (optional)").tag("none")
                Text("Administrators and helpdesk").tag("admins")
                Text("Everyone").tag("all")
            }
            NumberRow(title: "Minimum password length", value: s.int("security.passwordMinLength"))
            NumberRow(title: "Session length (days)", value: s.int("security.sessionDays"))
            NumberRow(title: "Failed sign-ins before a 15-minute lockout", value: s.int("security.maxLoginAttempts"))
            ToggleRow(title: "Allow people to forward mail outside this server", isOn: s.bool("mail.allowExternalForwarding"), help: "Turn off so mail can’t leave through forwarding rules.")
            ToggleRow(title: "People can delete their own account", isOn: s.bool("users.selfDelete"), help: "In Settings → Security, with their password (and 2-step code). Their mail goes and their addresses are freed. Turn off to have them ask an administrator.")
            ToggleRow(title: "Let people use mail apps (JMAP)", isOn: s.bool("jmap.enabled"), help: "People make an app password in Settings → Security and sign in to a mail app, like this one, with it. To leave someone out, turn mail apps off on their page in Users. Turning this off stops every app at once, this admin panel included.")
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed IPs and ranges")
                TextEditor(text: s.text("security.adminIpAllowlist"))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(minHeight: 70)
                SettingHelp("One per line (or separated by commas). IPv4 and IPv6, single addresses or ranges such as 203.0.113.0/24 or 2001:db8::/48.")
            }
            LabeledContent("This Mac’s IP address") {
                HStack {
                    Text(mine.isEmpty ? "Unknown" : mine).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if !mine.isEmpty && !listed {
                        Button("Add It") {
                            let list = (s["security.adminIpAllowlist"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            s.set("security.adminIpAllowlist", .string(list.isEmpty ? mine : "\(list)\n\(mine)"))
                        }
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Admin panel access")
        } footer: {
            Text("Only allow the admin panel, here and on the web, from these addresses, for every administrator. Leave empty to allow it from anywhere. Mail and everyone’s own settings aren’t affected. Wren won’t save a list that leaves out your current address.")
        }
    }

    private var mine: String { clientIp ?? "" }

    private var listed: Bool {
        (s["security.adminIpAllowlist"]?.string ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).contains { String($0) == mine }
    }
}

// MARK: Limits

private struct LimitsSettings: View {
    let s: SettingsBinder

    var body: some View {
        Section {
            NumberRow(title: "Mailbox quota (MB)", value: s.int("limits.defaultQuotaMb"))
            NumberRow(title: "Messages sent per day", value: s.int("limits.defaultSendPerDay"))
            NumberRow(title: "Largest attachment (MB)", value: s.int("limits.maxAttachmentMb"))
            NumberRow(title: "Most recipients per message", value: s.int("limits.maxRecipients"))
            NumberRow(title: "Delivery retries", value: s.int("mail.maxRetries"), help: "Temporary failures are tried again, waiting longer each time (30 seconds up to 4 hours).")
            ToggleRow(title: "Deliver mail between hosted domains internally", isOn: s.bool("mail.localDelivery"), help: "Faster and free: messages to other people on this server never leave it.")
        } header: {
            Text("Default limits")
        } footer: {
            Text("For people without their own value.")
        }
        Section {
            Toggle("Pause sending on unusual activity", isOn: s.bool("guard.enabled"))
            NumberRow(title: "Messages per hour", value: s.int("guard.maxPerHour"), help: "Sending more than this in an hour pauses the account.")
                .disabled(s["guard.enabled"]?.bool != true)
            NumberRow(title: "Bounce rate (%)", value: s.int("guard.bounceRatePercent"), help: "Hard bounces over the last 24 hours, checked once someone has sent 20 messages.")
                .disabled(s["guard.enabled"]?.bool != true)
        } header: {
            Text("Compromised-account guard")
        } footer: {
            Text("Pauses someone’s sending when it looks like their account is sending spam. They can still read and receive mail; their queued mail is held and admins get an alert. Resume sending from their page in Users.")
        }
    }
}

// MARK: Spam and blocking

private struct SpamSettings: View {
    let panel: AdminPanel
    let s: SettingsBinder
    let defaults: [String: JSON]?
    let blocked: [AdminBlocked]
    @State private var ext = ""
    @State private var pattern = ""

    var body: some View {
        Section {
            Toggle("Spam filtering", isOn: s.bool("spam.enabled"))
            VStack(alignment: .leading, spacing: 3) {
                LabeledContent("Spam threshold") {
                    TextField("Spam threshold", value: s.double("spam.threshold"), format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                SettingHelp("Messages scoring this or more go to Spam. Lower is stricter (the default is 6).")
            }
            VStack(alignment: .leading, spacing: 3) {
                TextField("rspamd URL", text: s.text("spam.rspamdUrl"), prompt: Text("http://localhost:11333"))
                SettingHelp("Optional. When set, rspamd’s score replaces the built-in one.")
            }
            SecureField("rspamd password", text: s.secret("spam.rspamdPassword"), prompt: Text(s.isMasked("spam.rspamdPassword") ? "Saved. Type to replace it" : ""))
        } header: {
            Text("Spam filtering")
        } footer: {
            Text("Built-in scoring uses SPF, DKIM and DMARC results, provider verdicts and the message itself. Connect rspamd for stronger filtering.")
        }
        attachments
        blocklist
    }

    private var types: [String] { (s["attachments.blockedTypes"]?.array ?? []).compactMap(\.string) }

    private var attachments: some View {
        Section {
            Picker("When a message has one", selection: s.text("attachments.action")) {
                Text("Add to its spam score").tag("score")
                Text("Always put it in Spam").tag("spam")
                Text("Refuse the message").tag("reject")
            }
            if types.isEmpty {
                Text("No types blocked.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(types, id: \.self) { t in
                        HStack(spacing: 2) {
                            Text(".\(t)")
                            Button { setTypes(types.filter { $0 != t }) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Remove .\(t)")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
            }
            HStack {
                TextField("Add a type", text: $ext, prompt: Text("iso or .lnk"))
                    .onSubmit(addTypes)
                Button("Add", action: addTypes).disabled(ext.trimmingCharacters(in: .whitespaces).isEmpty)
                if let d = defaults {
                    Button("Reset to Defaults") {
                        if let t = d["attachments.blockedTypes"] { s.set("attachments.blockedTypes", t) }
                        if let a = d["attachments.action"] { s.set("attachments.action", a) }
                    }
                    .disabled(d["attachments.blockedTypes"] == s["attachments.blockedTypes"] && d["attachments.action"] == s["attachments.action"])
                }
            }
        } header: {
            Text("Risky attachments")
        } footer: {
            Text("Incoming mail with an attachment whose last extension is on this list (so invoice.pdf.exe counts as .exe). Archives aren’t opened.")
        }
    }

    private func setTypes(_ list: [String]) {
        s.set("attachments.blockedTypes", .array(list.map(JSON.string)))
    }

    private func addTypes() {
        let added = ext.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0.drop(while: { $0 == "." })).lowercased() }
            .filter { !$0.isEmpty && !types.contains($0) }
        if !added.isEmpty {
            var seen = Set<String>()
            setTypes((types + added).filter { seen.insert($0).inserted })
        }
        ext = ""
    }

    /// Changes at once (it isn't one of the settings that wait for Save).
    private var blocklist: some View {
        Section {
            HStack {
                TextField("Block a sender or domain", text: $pattern, prompt: Text("bad@example.com or example.com"))
                    .onSubmit(block)
                Button("Block", action: block).disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if blocked.isEmpty {
                Text("Nothing blocked.").foregroundStyle(.secondary)
            }
            ForEach(blocked) { b in
                HStack {
                    Text(b.pattern).textSelection(.enabled)
                    Spacer()
                    Text(adminAgo(b.createdAt)).font(.caption).foregroundStyle(.secondary)
                    Button("Remove") {
                        panel.change("DELETE", "/blocklist/\(b.id)") { _ in (text: "\(b.pattern) is no longer blocked.", link: nil) }
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Server-wide blocklist")
        } footer: {
            Text("Mail from these senders or domains is refused for everyone. This list changes straight away, without Save.")
        }
    }

    private func block() {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        panel.change("POST", "/blocklist", ["pattern": .string(p)]) { _ in (text: "Mail from \(p) is refused now.", link: nil) }
        pattern = ""
    }
}

// MARK: Alerts and retention

private struct AlertSettings: View {
    let s: SettingsBinder

    var body: some View {
        Section {
            ToggleRow(title: "Tell admins about new alerts", isOn: s.bool("alerts.email"), help: "A message in each admin’s inbox, and a notification for critical ones. Alerts always show on the Overview page.")
            VStack(alignment: .leading, spacing: 3) {
                TextField("Also email alerts to", text: s.text("alerts.externalTo"), prompt: Text("you@example.com"))
                SettingHelp("An address outside this server, so you hear about problems even when Wren’s own mail is down. Blank for none.")
            }
            NumberRow(title: "Queue backlog alert at", value: s.int("alerts.queueThreshold"), help: "Messages waiting to go out.")
            NumberRow(title: "Mailbox full alert at (%)", value: s.int("alerts.quotaPercent"), help: "Of a person’s quota.")
        } header: {
            Text("Alerts")
        } footer: {
            Text("Wren watches for a failing provider, a stuck send queue, full mailboxes and DNS changes, and tells admins.")
        }
    }
}

private struct RetentionSettings: View {
    let s: SettingsBinder

    var body: some View {
        Section {
            NumberRow(title: "Empty Trash after (days)", value: s.int("retention.trashDays"))
            NumberRow(title: "Delete Spam after (days)", value: s.int("retention.spamDays"))
        } header: {
            Text("Automatic clean-up")
        } footer: {
            Text("Logs are kept 90 days. Files no message uses any more are cleared out daily.")
        }
    }
}
