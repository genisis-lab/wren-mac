import SwiftUI
import WrenKit

/// Admin → Domains: the domains this server hosts, their DNS, how they send and receive.
struct AdminDomainsPage: View {
    @Bindable var panel: AdminPanel
    @State private var domains: [AdminDomain]?
    @State private var providers: [AdminProvider] = []
    @State private var adding = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Domains").font(.headline)
                    Spacer()
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .help("Add Domain")
                        .accessibilityLabel("Add Domain")
                }
                .padding(8)
                List(domains ?? [], selection: $panel.selectedDomain) { d in
                    DomainRow(domain: d).tag(d.id)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            Group {
                if let id = panel.selectedDomain, let d = domains?.first(where: { $0.id == id }) {
                    AdminDomainDetailView(panel: panel, domain: d, providers: providers)
                        .id(id)
                } else if domains == nil {
                    AdminLoading()
                } else if domains!.isEmpty {
                    ContentUnavailableView("No Domains Yet", systemImage: "globe", description: Text("Add the domain you want to host mail for, then follow its DNS checklist."))
                } else {
                    ContentUnavailableView("No Domain Selected", systemImage: "globe", description: Text("Choose a domain to see its DNS records and settings."))
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: panel.generation) {
            domains = await panel.fetch("/domains", as: DomainList.self)?.domains
            providers = await panel.fetch("/providers", as: ProviderList.self)?.providers ?? []
        }
        .sheet(isPresented: $adding) { AddDomainSheet(panel: panel, providers: providers) }
    }
}

struct ProviderList: Decodable { var providers: [AdminProvider] }

private struct DomainRow: View {
    let domain: AdminDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(!domain.enabled ? Color.secondary : domain.verified ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(!domain.enabled ? "Disabled" : domain.verified ? "Verified" : "Not verified")
                Text(domain.name).lineLimit(1)
                if !domain.enabled { AdminBadge(text: "Disabled") }
            }
            if let dns = domain.dns {
                HStack(spacing: 4) {
                    DNSBadge(name: "MX", ok: dns.mx?.ok)
                    DNSBadge(name: "SPF", ok: dns.spfOK)
                    DNSBadge(name: "DKIM", ok: dns.dkimOK)
                    DNSBadge(name: "DMARC", ok: dns.dmarc?.ok, warnOnly: true)
                }
            } else {
                Text("DNS not checked yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DNSBadge: View {
    let name: String
    let ok: Bool?
    var warnOnly = false

    var body: some View {
        AdminBadge(text: "\(ok == nil ? "·" : ok! ? "✓" : "✕") \(name)", tone: ok == nil ? .plain : ok! ? .ok : warnOnly ? .warn : .danger)
            .accessibilityLabel("\(name) \(ok == nil ? "not checked" : ok! ? "OK" : "missing")")
    }
}

private struct AddDomainSheet: View {
    let panel: AdminPanel
    let providers: [AdminProvider]
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var provider: Int?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Domain").font(.headline)
            Form {
                TextField("Domain name", text: $name, prompt: Text("example.com"))
                ProviderPicker(title: "Send through", providers: providers, selection: $provider, none: "Default provider")
            }
            Text("You can change the provider later.").font(.caption).foregroundStyle(.secondary)
            SheetButtons(error: error, busy: busy, action: "Add Domain", disabled: !name.contains("."), cancel: { dismiss() }) {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let r = try await panel.send("POST", "/domains", ["name": .string(name.trimmingCharacters(in: .whitespaces).lowercased()), "providerId": provider.map { JSON.number(Double($0)) } ?? .null])
                        panel.selectedDomain = r["id"]?.int
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

/// Outbound providers to choose from.
struct ProviderPicker: View {
    let title: String
    let providers: [AdminProvider]
    @Binding var selection: Int?
    let none: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text(none).tag(Int?.none)
            ForEach(providers.filter(\.outbound)) { p in
                Text(p.name == p.typeName ? p.name : "\(p.name) (\(p.typeName))").tag(Optional(p.id))
            }
        }
    }
}

// MARK: One domain

struct AdminDomainDetailView: View {
    let panel: AdminPanel
    let domain: AdminDomain
    let providers: [AdminProvider]
    @State private var detail: AdminDomainDetail?
    @State private var people: [AdminUser] = []
    @State private var catchAll: AdminCatchAll?
    @State private var cloudflare: AdminCloudflare?
    @State private var checking = false
    @State private var removing = false
    @State private var dkim = ""
    @State private var footer = ""

    private var d: AdminDomain { detail?.domain ?? domain }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.title3.bold())
                        Text(d.verified ? "Verified \(adminAgo(d.verifiedAt))" : "Ownership not verified yet: add the TXT record below.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(checking ? "Checking…" : "Check DNS") { check() }
                        .disabled(checking)
                    Button("Remove…", role: .destructive) { removing = true }
                }
            }
            records
            health
            sending
            receiving
            if let catchAll, d.catchAllUserId != nil || !catchAll.hits.isEmpty || !catchAll.blocked.isEmpty {
                CatchAllSection(panel: panel, domain: d, info: catchAll)
            }
            if let cloudflare { CloudflareSection(panel: panel, domain: d, cf: cloudflare) }
        }
        .formStyle(.grouped)
        .task(id: panel.generation) {
            detail = await panel.fetch("/domains/\(domain.id)")
            people = await panel.fetch("/users", as: UserList.self)?.users ?? []
            catchAll = await panel.fetch("/domains/\(domain.id)/catchall")
            cloudflare = await panel.fetch("/cloudflare")
            dkim = d.dkimSelector ?? ""
            footer = d.footerText ?? ""
        }
        .confirmationDialog("Remove \(d.name)?", isPresented: $removing) {
            Button("Remove Domain", role: .destructive) {
                panel.selectedDomain = nil
                panel.change("DELETE", "/domains/\(d.id)") { _ in (text: "\(d.name) removed.", link: nil) }
            }
        } message: {
            Text("Its aliases and groups are deleted. Mailboxes on it stay, but stop receiving mail.")
        }
    }

    @ViewBuilder private var records: some View {
        if let records = detail?.records, !records.isEmpty {
            Section {
                ForEach(Array(records.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            AdminBadge(text: r.type, tone: .accent)
                            if let p = r.priority { AdminBadge(text: "Priority \(p)") }
                            if r.optional == true { AdminBadge(text: "Optional") }
                        }
                        if let purpose = r.purpose {
                            Text(purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        CopyField(label: "Host", value: r.host)
                        CopyField(label: "Value", value: r.value)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("DNS records")
            } footer: {
                Text("Create these at your DNS host (Cloudflare, Route 53, Namecheap…). Values from your provider’s dashboard take precedence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var health: some View {
        Section(d.dns == nil ? "DNS health" : "DNS health, checked \(adminAgo(d.dnsCheckedAt))") {
            if let dns = d.dns {
                checkRow(dns.verification?.ok, "Ownership verification", dns.verification?.ok == true ? "TXT record found." : "Add TXT _wren.\(d.name) = \(dns.verification?.expected ?? "")")
                checkRow(dns.mx?.ok, "MX (receiving)", [dns.mx?.hint, dns.mx?.records?.map { "\($0.priority ?? 0) \($0.exchange)" }.joined(separator: " · ")].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n"))
                checkRow(dns.spfOK, dns.spf?.host.map { $0 != d.name ? "SPF (\($0))" : "SPF" } ?? "SPF",
                         (dns.spf?.record ?? "No SPF record found.") + (dns.spf?.includesProvider == false ? "\nMissing include:\(dns.spf?.expectedInclude ?? "") (fine if your provider uses its own return-path domain)." : ""))
                if (dns.dkim ?? []).isEmpty {
                    checkRow(nil, "DKIM", "Set the DKIM selector your provider uses (under Sending) to check it.")
                } else {
                    ForEach(dns.dkim ?? [], id: \.selector) { k in
                        checkRow(k.found, "DKIM (\(k.selector))", k.found ? String((k.value ?? "").prefix(120)) + "…" : "No record at \(k.selector)._domainkey.\(d.name)")
                    }
                }
                checkRow(dns.dmarc?.ok, dns.dmarc?.host.map { $0 != d.name ? "DMARC (from \($0))" : "DMARC" } ?? "DMARC",
                         dns.dmarc?.record.map { "Policy: \(dns.dmarc?.policy ?? "unknown") · \($0)" } ?? "No DMARC record: recommended for deliverability.", warnOnly: true)
                ForEach(dns.errors ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            } else {
                Text("Run a check to see what’s set up.").foregroundStyle(.secondary)
            }
        }
    }

    private func checkRow(_ ok: Bool?, _ title: String, _ detail: String, warnOnly: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            CheckMark(ok: ok, warnOnly: warnOnly)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.system(.caption, design: detail.contains("v=") ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sending: some View {
        Section("Sending") {
            ProviderPicker(title: "Outbound provider", providers: providers, selection: binding(\.providerId, "providerId"), none: "Default provider")
            ProviderPicker(title: "Fallback provider", providers: providers, selection: binding(\.fallbackProviderId, "fallbackProviderId"), none: "None")
            HStack {
                TextField("DKIM selectors", text: $dkim, prompt: Text("Provider default"))
                Button("Save") { update(["dkimSelector": dkim.isEmpty ? .null : .string(dkim)]) }
                    .disabled(dkim == (d.dkimSelector ?? ""))
            }
            Text("Comma-separated, such as resend or s1,s2. Used by the DNS check.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Footer")
                TextEditor(text: $footer)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                HStack {
                    Text("Plain text added to the end of mail sent from this domain, such as a disclaimer. Not added to signed or encrypted mail.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Footer") { update(["footerText": .string(String(footer.prefix(2000)))]) }
                        .disabled(footer == (d.footerText ?? ""))
                }
            }
            SenderStatus(panel: panel, domain: d.name)
        }
    }

    private var receiving: some View {
        Section("Receiving") {
            Picker("Catch-all mailbox", selection: binding(\.catchAllUserId, "catchAllUserId")) {
                Text("Off: reject unknown addresses").tag(Int?.none)
                ForEach(people.filter { $0.email.lowercased().hasSuffix("@\(d.name)") }) { Text($0.email).tag(Optional($0.id)) }
            }
            Toggle("Domain enabled", isOn: Binding(get: { d.enabled }, set: { update(["enabled": .bool($0)]) }))
            Text("Disabled domains don’t receive mail and can’t be sent from.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// An optional id on the domain, saved as soon as it's picked.
    private func binding(_ key: KeyPath<AdminDomain, Int?>, _ field: String) -> Binding<Int?> {
        Binding(get: { d[keyPath: key] }, set: { v in update([field: v.map { JSON.number(Double($0)) } ?? .null]) })
    }

    private func update(_ patch: [String: JSON]) {
        panel.change("PUT", "/domains/\(d.id)", .object(patch)) { _ in (text: "\(d.name) updated.", link: nil) }
    }

    private func check() {
        checking = true
        Task {
            defer { checking = false }
            do { try await panel.send("POST", "/domains/\(d.id)/check") } catch { panel.error = error.localizedDescription }
        }
    }
}

struct UserList: Decodable { var users: [AdminUser] }

/// What the sending provider says about a domain.
struct SenderStatus: View {
    let panel: AdminPanel
    let domain: String
    @State private var check: AdminSenderCheck?

    var body: some View {
        // Always something on screen, so the check runs.
        Label {
            Text(check?.detail ?? "Asking the sending provider about \(domain)…")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            CheckMark(ok: check?.verified, warnOnly: true)
        }
        .task(id: domain) {
            check = await panel.fetch("/sending-check?domain=\(domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain)")
        }
    }
}

/// Mail the catch-all took for addresses without a mailbox: block what only gets spam, or make it a real alias.
private struct CatchAllSection: View {
    let panel: AdminPanel
    let domain: AdminDomain
    let info: AdminCatchAll
    @State private var block = ""

    var body: some View {
        Section {
            if info.hits.isEmpty {
                Text(domain.catchAllUserId != nil ? "Nothing yet. Mail to unknown addresses will be listed here." : "The catch-all is off.")
                    .foregroundStyle(.secondary)
            }
            ForEach(info.hits) { h in hit(h) }
            ForEach(info.blocked) { b in
                HStack {
                    Text(b.address)
                    AdminBadge(text: "Blocked", tone: .danger)
                    Spacer()
                    Button("Unblock") { change("DELETE", "/blocked-recipients/\(escaped(b.address))", note: "\(b.address) unblocked.") }
                }
            }
            HStack {
                TextField("Block an address", text: $block, prompt: Text("leaked@\(domain.name)"))
                Button("Block") {
                    let a = block.contains("@") ? block.trimmingCharacters(in: .whitespaces) : "\(block.trimmingCharacters(in: .whitespaces))@\(domain.name)"
                    change("POST", "/blocked-recipients", ["address": .string(a)], note: "Mail to \(a) will be refused.")
                    block = ""
                }
                .disabled(block.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Catch-all activity")
        } footer: {
            Text("Addresses without a mailbox or alias that received mail through the catch-all. Mail to blocked addresses is refused, even with the catch-all on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func hit(_ h: AdminCatchAll.Hit) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(h.address).strikethrough(h.blocked)
                Text("\(h.count) message\(h.count == 1 ? "" : "s") · last \(adminAgo(h.lastAt)) from \(h.lastFrom ?? "unknown")\(h.lastSubject.map { " · “\($0)”" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if h.blocked {
                Button("Unblock") { change("DELETE", "/blocked-recipients/\(escaped(h.address))", note: "\(h.address) unblocked.") }
            } else {
                Button("Make Alias") { change("POST", "/catchall/alias", ["address": .string(h.address)], note: "\(h.address) is now an alias.") }
                Button("Block") { change("POST", "/blocked-recipients", ["address": .string(h.address)], note: "Mail to \(h.address) will be refused.") }
            }
            Button { change("DELETE", "/catchall/hits/\(escaped(h.address))", note: "Hidden until it gets mail again.") } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Hide from this list until it gets mail again")
                .accessibilityLabel("Hide \(h.address) from this list")
        }
    }

    private func escaped(_ address: String) -> String {
        address.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? address
    }

    private func change(_ method: String, _ path: String, _ body: JSON? = nil, note: String) {
        panel.change(method, path, body) { _ in (text: note, link: nil) }
    }
}

/// One-click Cloudflare setup: Email Routing to this Worker, plus Email Sending.
private struct CloudflareSection: View {
    let panel: AdminPanel
    let domain: AdminDomain
    let cf: AdminCloudflare
    @State private var token = ""
    @State private var worker = ""
    @State private var sending = true
    @State private var moveMx = false
    @State private var steps: [AdminSetupStep]?
    @State private var busy = false
    @State private var removing = false

    /// MX records pointing somewhere other than Cloudflare: that service stops receiving if routing is turned on.
    private var elsewhere: [String] {
        (domain.dns?.mx?.records ?? []).map(\.exchange).filter { !$0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix(".mx.cloudflare.net") }
    }

    var body: some View {
        Section {
            if !cf.configured {
                Text("Create an API token in the Cloudflare dashboard (My Profile → API Tokens) with Zone: Read, DNS: Edit, Email Routing Rules: Edit, Zone Settings: Edit and Email Sending: Edit for this zone. It’s stored encrypted.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("API token", text: $token)
                TextField("Worker name", text: $worker, prompt: Text(cf.workerName ?? "wren"))
                Button("Save Token") { saveToken() }
                    .disabled(token.trimmingCharacters(in: .whitespaces).count < 20 || busy)
            } else {
                Toggle("Also set up sending", isOn: $sending)
                if !elsewhere.isEmpty {
                    Label("Mail for \(domain.name) goes to \(elsewhere.joined(separator: ", ")) today. Turning on Email Routing replaces those MX records, and that service stops receiving it.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Yes, move this domain’s mail to Cloudflare", isOn: $moveMx)
                }
                HStack {
                    Button(steps == nil ? "Set Up Now" : "Run Again") { run() }
                        .disabled(busy || (!elsewhere.isEmpty && !moveMx))
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Remove Token…") { removing = true }
                        .confirmationDialog("Remove the stored Cloudflare token?", isPresented: $removing) {
                            Button("Remove Token", role: .destructive) { panel.change("DELETE", "/cloudflare") }
                        }
                }
                ForEach(steps ?? []) { step in
                    HStack(alignment: .top) {
                        CheckMark(ok: step.status == "done" || step.status == "skipped", warnOnly: step.status == "warn")
                        VStack(alignment: .leading) {
                            Text(step.title).fontWeight(.medium).foregroundStyle(step.status == "failed" ? Color.red : Color.primary)
                            Text(step.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } header: {
            Text("Set up with Cloudflare")
        } footer: {
            Text("Turns on Email Routing to this Worker and Email Sending for the domain, and creates the DNS records.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveToken() {
        var body: [String: JSON] = ["apiToken": .string(token.trimmingCharacters(in: .whitespaces))]
        if !worker.trimmingCharacters(in: .whitespaces).isEmpty { body["workerName"] = .string(worker.trimmingCharacters(in: .whitespaces)) }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await panel.send("PUT", "/cloudflare", .object(body))
                token = ""
                panel.notice = (text: "Cloudflare token saved.", link: nil)
            } catch {
                panel.error = error.localizedDescription
            }
        }
    }

    private struct Steps: Decodable { var steps: [AdminSetupStep] }

    private func run() {
        busy = true
        steps = nil
        Task {
            defer { busy = false }
            do {
                let r = try await panel.send("POST", "/domains/\(domain.id)/cloudflare-setup", ["sending": .bool(sending), "replaceMx": .bool(!elsewhere.isEmpty && moveMx)])
                steps = (try? JSONDecoder().decode(Steps.self, from: JSONEncoder().encode(r)))?.steps ?? []
            } catch {
                panel.error = error.localizedDescription
            }
        }
    }
}
