import AppKit
import SwiftUI
import WrenKit

/// Admin → Providers: the services Wren sends and receives mail through.
struct AdminProvidersPage: View {
    @Bindable var panel: AdminPanel
    @State private var providers: [AdminProvider]?
    @State private var types: [AdminProviderType] = []
    @State private var selected: Int?
    @State private var picking = false
    @State private var connecting: AdminProviderType?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Providers").font(.headline)
                    Spacer()
                    Button { picking = true } label: { Image(systemName: "plus") }
                        .help("Add Provider")
                        .accessibilityLabel("Add Provider")
                        .disabled(types.isEmpty)
                }
                .padding(8)
                List(providers ?? [], selection: $selected) { p in
                    ProviderRow(provider: p).tag(p.id)
                }
            }
            .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: panel.generation) {
            providers = await panel.fetch("/providers", as: ProviderList.self)?.providers
            if types.isEmpty { types = await panel.fetch("/provider-types", as: TypeList.self)?.types ?? [] }
        }
        .sheet(isPresented: $picking) {
            ProviderTypePicker(types: types) { t in
                picking = false
                connecting = t
            }
        }
        .sheet(item: $connecting) { t in
            ProviderEditor(panel: panel, type: t, id: nil) { id in
                connecting = nil
                selected = id
            }
            .frame(width: 560, height: 640)
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selected, let p = providers?.first(where: { $0.id == id }) {
            if let t = types.first(where: { $0.type == p.type }) {
                ProviderEditor(panel: panel, type: t, id: id) { _ in selected = nil }
                    .id(id)
            } else {
                ContentUnavailableView("Unknown Provider Type", systemImage: "questionmark.circle", description: Text("This server doesn’t know the type “\(p.type)” any more."))
            }
        } else if providers == nil {
            AdminLoading()
        } else if providers!.isEmpty {
            ContentUnavailableView {
                Label("No Providers Connected", systemImage: "powerplug")
            } description: {
                Text("Wren sends and receives through services like Cloudflare Email Service, Resend, Amazon SES, Postmark and more, or plain SMTP.")
            } actions: {
                Button("Connect a Provider") { picking = true }.disabled(types.isEmpty)
            }
        } else {
            ContentUnavailableView("No Provider Selected", systemImage: "powerplug", description: Text("Choose a provider to change its settings or send a test."))
        }
    }

    private struct TypeList: Decodable { var types: [AdminProviderType] }
}

private struct ProviderRow: View {
    let provider: AdminProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(!provider.enabled ? Color.secondary : provider.hasRecentError ? Color.red : Color.green)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(!provider.enabled ? "Disabled" : provider.hasRecentError ? "Failing" : "Working")
                Text(provider.name).lineLimit(1)
                if provider.isDefault { AdminBadge(text: "Default", tone: .accent) }
                if !provider.enabled { AdminBadge(text: "Disabled") }
            }
            Text(usedFor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if provider.hasRecentError, let e = provider.lastError {
                Text("Last error \(adminAgo(provider.lastErrorAt)): \(e)").font(.caption).foregroundStyle(.red).lineLimit(2)
            } else {
                Text(counts).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var usedFor: String {
        let kind = provider.outbound && provider.inbound ? "Sending and receiving" : provider.outbound ? "Sending" : "Receiving"
        return provider.name.lowercased() == provider.typeName.lowercased() ? kind : "\(provider.typeName) · \(kind)"
    }

    private var counts: String {
        var parts: [String] = []
        if provider.outbound { parts.append("\(provider.sentCount ?? 0) sent") }
        if provider.inbound { parts.append("\(provider.receivedCount ?? 0) received") }
        if let f = provider.failedCount, f > 0 { parts.append("\(f) failed") }
        if !provider.domains.isEmpty { parts.append("used by \(provider.domains.joined(separator: ", "))") }
        else if provider.isDefault { parts.append("used by domains without their own") }
        return parts.joined(separator: " · ")
    }
}

/// Choose what to connect, grouped as on the web.
private struct ProviderTypePicker: View {
    let types: [AdminProviderType]
    let pick: (AdminProviderType) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a Provider").font(.headline)
            TextField("Search providers", text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(AdminProviderType.categories, id: \.key) { c in
                    let items = shown.filter { $0.category == c.key }
                    if !items.isEmpty {
                        Section(c.title) {
                            ForEach(items) { t in
                                Button { pick(t) } label: { TypeRow(type: t) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }

    private var shown: [AdminProviderType] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? types : types.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        // Recommended ones first in each group.
        return list.sorted { ($0.recommended == true ? 0 : 1, $0.name) < ($1.recommended == true ? 0 : 1, $1.name) }
    }
}

private struct TypeRow: View {
    let type: AdminProviderType

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(type.name).fontWeight(.medium)
                if type.recommended == true { AdminBadge(text: "Recommended", tone: .ok) }
                if type.outbound { AdminBadge(text: "Send") }
                if type.inbound { AdminBadge(text: "Receive") } else if let via = type.inboundVia { AdminBadge(text: "Receive via \(via)") }
            }
            Text(type.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

// MARK: Editing

/// A provider's settings: connecting a new one, or changing, testing and deleting one that's connected.
private struct ProviderEditor: View {
    let panel: AdminPanel
    let type: AdminProviderType
    let id: Int?
    /// After connecting (with the new id) or cancelling (nil).
    let done: (Int?) -> Void

    @State private var loaded = false
    @State private var name = ""
    @State private var enabled = true
    @State private var isDefault = false
    @State private var config: [String: JSON] = [:]
    @State private var inboundUrl: String?
    @State private var busy = false
    @State private var error: String?
    @State private var result: (ok: Bool, message: String)?
    @State private var testFrom = ""
    @State private var testTo = ""
    @State private var rotating = false
    @State private var deleting = false

    /// What the server sends back in place of a saved secret.
    static let mask = "••••••••"

    var body: some View {
        Form {
            Section { header }
            if id != nil && !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else {
                Section("Settings") {
                    TextField("Name", text: $name)
                    if let presets = type.presets, !presets.isEmpty {
                        Picker("Preset", selection: Binding(get: { "" }, set: { label in
                            if let p = presets.first(where: { $0.label == label }) { config.merge(p.values) { $1 } }
                        })) {
                            Text("Choose a preset…").tag("")
                            ForEach(presets, id: \.label) { Text($0.label).tag($0.label) }
                        }
                    }
                    ForEach(type.fields) { f in ProviderField(field: f, value: binding(f.key)) }
                    Toggle("Enabled", isOn: $enabled)
                    if type.outbound {
                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Default outbound provider", isOn: $isDefault)
                            Text("Used by domains without their own provider.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                setup
                if id != nil && type.outbound { testBox }
                Section { buttons }
            }
        }
        .formStyle(.grouped)
        .task {
            let me = panel.login?.username ?? ""
            testFrom = me
            testTo = me
            guard let id else {
                name = type.name
                config = type.defaults
                loaded = true
                return
            }
            await load(id)
        }
        .sheet(isPresented: $deleting) {
            ConfirmSheet(
                title: "Delete \(name)?",
                message: "Domains that send through it fall back to the default provider. Webhooks pointing at its URL stop working.",
                action: "Delete Provider"
            ) {
                guard let id else { return }
                try await panel.send("DELETE", "/providers/\(id)")
                // The list reloads without it, which closes this page.
                panel.notice = (text: "\(name) deleted.", link: nil)
            }
        }
        .sheet(isPresented: $rotating) {
            ConfirmSheet(
                title: "Make a new webhook URL?",
                message: "The old URL stops working at once. Paste the new one into \(type.name) straight away, or mail sent there is turned away.",
                action: "Make New URL"
            ) {
                guard let id else { return }
                let r = try await panel.send("POST", "/providers/\(id)/rotate-token")
                inboundUrl = r["inboundUrl"]?.string ?? inboundUrl
            }
        }
    }

    private func load(_ id: Int) async {
        guard let p = await panel.fetch("/providers/\(id)", as: One.self)?.provider else { return }
        name = p.name
        enabled = p.enabled
        isDefault = p.isDefault
        config = p.config ?? [:]
        inboundUrl = p.inboundUrl
        loaded = true
    }

    private func binding(_ key: String) -> Binding<JSON> {
        Binding(get: { config[key] ?? .string("") }, set: { config[key] = $0 })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(id == nil ? "Connect \(type.name)" : name.isEmpty ? type.name : name).font(.title2.bold())
            Text(type.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let site = type.website, let url = URL(string: site) {
                Link(url.host ?? site, destination: url).font(.callout)
            }
        }
    }

    /// How to point the provider at Wren: sending, receiving and delivery status.
    @ViewBuilder private var setup: some View {
        if type.outbound, let text = type.outboundSetup {
            SetupBox(title: "Sending setup", icon: "arrow.up.circle", text: fill(text))
        }
        if type.inbound {
            SetupBox(title: "Receiving setup", icon: "arrow.down.circle", text: fill(type.inboundSetup ?? "")) {
                urlBox(label: "Inbound URL")
            }
        }
        if type.outbound, let text = type.eventsSetup {
            let lead = type.eventsWebhook == true ? "Bounces and spam complaints show in the delivery log, and those addresses aren’t mailed again. " : ""
            SetupBox(title: "Delivery status", icon: "waveform.path.ecg", text: lead + fill(text)) {
                if type.eventsWebhook == true && !type.inbound { urlBox(label: "Webhook URL") }
            }
        }
    }

    @ViewBuilder private func urlBox(label: String) -> some View {
        if let url = inboundUrl {
            CopyField(label: label, value: url)
            Text("Keep this URL secret: anyone with it can deliver mail to your people.").font(.caption).foregroundStyle(.secondary)
            if id != nil {
                Button("Make a New URL…") { rotating = true }.controlSize(.small)
            }
        } else {
            Text("Connect the provider to get its URL.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fill(_ text: String) -> String {
        text.replacingOccurrences(of: "{{url}}", with: inboundUrl ?? "the webhook URL (shown once it’s connected)")
    }

    private var testBox: some View {
        Section("Test the connection") {
            TextField("From", text: $testFrom)
            TextField("To", text: $testTo)
            HStack {
                Button("Check Credentials") { check("/verify", nil) }
                Button("Send Test Email") {
                    check("/test", ["from": .string(testFrom.trimmingCharacters(in: .whitespaces)), "to": .string(testTo.trimmingCharacters(in: .whitespaces))])
                }
                .disabled(!testFrom.contains("@") || !testTo.contains("@"))
            }
            .disabled(busy)
            if let result {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.ok ? Color.green : Color.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if id != nil {
                    Button("Delete…", role: .destructive) { deleting = true }
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if id == nil {
                    Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                }
                Button(id == nil ? "Connect" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        result = nil
        let body: JSON = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)), "enabled": .bool(enabled), "isDefault": .bool(isDefault),
            "config": .object(config),
        ]
        Task {
            defer { busy = false }
            do {
                if let id {
                    try await panel.send("PUT", "/providers/\(id)", body)
                    panel.notice = (text: "\(name) saved.", link: nil)
                } else {
                    var create = body.object ?? [:]
                    create["type"] = .string(type.type)
                    let r = try await panel.send("POST", "/providers", .object(create))
                    panel.notice = (text: "\(name) connected. Send a test email to check it works.", link: nil)
                    done(r["id"]?.int)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func check(_ path: String, _ body: JSON?) {
        guard let id else { return }
        busy = true
        result = nil
        Task {
            defer { busy = false }
            do {
                let r = try await panel.send("POST", "/providers/\(id)\(path)", body).decode(AdminCheckResult.self)
                result = (r.ok, r.message)
            } catch {
                result = (false, error.localizedDescription)
            }
        }
    }

    private struct One: Decodable { var provider: AdminProvider }
}

/// One setting of a provider, drawn the way its type says.
private struct ProviderField: View {
    let field: AdminProviderType.Field
    @Binding var value: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            if let help = field.help {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var label: String {
        field.label + (field.required == true ? " (required)" : "") + (field.inbound == true ? " · inbound" : "")
    }

    @ViewBuilder private var control: some View {
        switch field.type {
        case "boolean":
            Toggle(label, isOn: Binding(get: { value.bool ?? (value.string == "true") }, set: { value = .bool($0) }))
        case "select":
            Picker(label, selection: text) {
                ForEach(field.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
        case "textarea":
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                TextEditor(text: text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 70)
            }
        case "password":
            SecureField(label, text: secret, prompt: Text(value.string == ProviderEditor.mask ? "Saved. Type to replace it" : field.placeholder ?? ""))
        default:
            TextField(label, text: text, prompt: field.placeholder.map { Text($0) })
                .autocorrectionDisabled()
        }
    }

    /// The value as text: numbers without a fraction when they're whole.
    private var text: Binding<String> {
        Binding(get: {
            switch value {
            case .string(let s): s
            case .number(let n): Int(exactly: n).map(String.init) ?? String(n)
            case .bool(let b): b ? "true" : "false"
            default: ""
            }
        }, set: { value = .string($0) })
    }

    /// A saved secret comes back masked: it shows empty, and stays as it is unless you type a new one.
    private var secret: Binding<String> {
        Binding(get: { value.string == ProviderEditor.mask ? "" : value.string ?? "" }, set: { new in
            value = .string(new.isEmpty && value.string == ProviderEditor.mask ? ProviderEditor.mask : new)
        })
    }
}

/// How to set a provider up for one direction.
private struct SetupBox<Extra: View>: View {
    let title: String
    let icon: String
    let text: String
    let extra: Extra

    init(title: String, icon: String, text: String, @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.icon = icon
        self.text = text
        self.extra = extra()
    }

    var body: some View {
        Section {
            Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            extra
        } header: {
            Label(title, systemImage: icon)
        }
    }
}

extension SetupBox where Extra == EmptyView {
    init(title: String, icon: String, text: String) {
        self.init(title: title, icon: icon, text: text) { EmptyView() }
    }
}

/// "Are you sure?" for a change that can't be taken back, with the server's answer if it refuses.
struct ConfirmSheet: View {
    let title: String
    let message: String
    let action: String
    var destructive = true
    let perform: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SheetButtons(error: error, busy: busy, action: action, destructive: destructive, cancel: { dismiss() }) {
                busy = true
                error = nil
                Task {
                    defer { busy = false }
                    do {
                        try await perform()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
