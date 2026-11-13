import SwiftUI
import WrenKit

/// "?a=1&b=2" from the values that aren't empty, each encoded so "+" and "&" in a search stay as typed.
func adminQuery(_ items: KeyValuePairs<String, String?>) -> String {
    var safe = CharacterSet.alphanumerics
    safe.insert(charactersIn: "-._~")
    let parts = items.compactMap { key, value -> String? in
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: safe) ?? value)"
    }
    return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
}

/// Waits a moment after typing in a search box, so each key doesn't send a search. False when typing went on.
private func settle(_ search: String) async -> Bool {
    guard !search.isEmpty else { return true }
    try? await Task.sleep(for: .milliseconds(300))
    return !Task.isCancelled
}

private func subjectText(_ s: String?) -> String { s?.isEmpty == false ? s! : "(no subject)" }

// MARK: Mail queue

/// Admin → Mail Queue: every outgoing delivery (people's mail, forwards, automatic replies, notices).
struct AdminQueuePage: View {
    @Bindable var panel: AdminPanel
    @State private var status = ""
    @State private var search = ""
    @State private var items: [AdminQueued]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search sender, recipient, subject", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                Picker("Status", selection: $status) {
                    Text("All statuses").tag("")
                    Text("Queued").tag("queued")
                    Text("Sending").tag("sending")
                    Text("Sent").tag("sent")
                    Text("Failed").tag("failed")
                    Text("Cancelled").tag("cancelled")
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(10)
            if let items, items.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "tray", description: Text(search.isEmpty && status.isEmpty ? "Nothing has been sent yet." : "Nothing matches."))
            } else if let items {
                List(items) { QueueRow(panel: panel, item: $0) }
            } else {
                AdminLoading()
            }
        }
        .task(id: "\(panel.generation)|\(status)|\(search)") {
            guard await settle(search) else { return }
            items = await panel.fetch("/outbox" + adminQuery(["status": status, "q": search]), as: Items.self)?.items
        }
    }

    private struct Items: Decodable { var items: [AdminQueued] }
}

private struct QueueRow: View {
    let panel: AdminPanel
    let item: AdminQueued

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                AdminBadge(text: item.status, tone: AdminBadge.tone(item.status))
                if let kind = item.kind { Text(kind).font(.caption2).foregroundStyle(.tertiary) }
            }
            .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(subjectText(item.subject)).lineLimit(1)
                Text("\(item.from ?? "") → \(item.recipients.isEmpty ? "(local only)" : item.recipients.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let e = item.lastError, item.status != "sent" {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                }
                if let p = item.provider { Text("via \(p)").font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(adminAgo(item.updatedAt)).font(.caption).foregroundStyle(.secondary)
                Text("\(item.attempts ?? 0) attempt\(item.attempts == 1 ? "" : "s")").font(.caption2).foregroundStyle(.tertiary)
                if item.status == "failed" || item.status == "cancelled" {
                    Button("Retry") { panel.change("POST", "/outbox/\(item.id)/retry") { _ in (text: "Queued again.", link: nil) } }
                        .controlSize(.small)
                } else if item.status == "queued" {
                    Button("Cancel") { panel.change("POST", "/outbox/\(item.id)/cancel") { _ in (text: "Cancelled. It won’t be sent.", link: nil) } }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Delivery logs

/// Admin → Delivery Logs: what happened to each message going out and coming in (kept 90 days), and the
/// addresses Wren won't mail.
struct AdminLogsPage: View {
    @Bindable var panel: AdminPanel
    @State private var tab = Tab.outbound
    @State private var filters: AdminLogFilters?

    enum Tab: Hashable { case outbound, inbound, suppressed }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Outbound").tag(Tab.outbound)
                Text("Inbound").tag(Tab.inbound)
                Text("Suppressed Addresses").tag(Tab.suppressed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(10)
            switch tab {
            case .outbound: DeliveryLog(panel: panel, filters: filters)
            case .inbound: InboundLog(panel: panel, filters: filters)
            case .suppressed: SuppressedList(panel: panel)
            }
        }
        .task(id: panel.generation) { filters = await panel.fetch("/log-filters") }
    }
}

/// A log entry to open.
private struct LogTarget: Identifiable {
    enum Kind { case delivery, inbound }
    let kind: Kind
    let id: Int
}

private struct DeliveryLog: View {
    let panel: AdminPanel
    let filters: AdminLogFilters?
    @State private var search = ""
    @State private var event = ""
    @State private var domain = ""
    @State private var user: Int?
    @State private var items: [AdminDeliveryEntry]?
    @State private var next: Double?
    @State private var loadingMore = false
    @State private var open: LogTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Recipient, subject, sender, error", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Picker("Event", selection: $event) {
                    Text("All events").tag("")
                    Text("Problems only").tag("problems")
                    Divider()
                    ForEach(["sent", "delivered", "deferred", "delayed", "bounced", "complained", "suppressed", "rejected", "failed"], id: \.self) { e in
                        Text(e == "complained" ? "Marked as spam" : e.capitalized).tag(e)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let f = filters, f.domains.count > 1 { DomainFilter(domains: f.domains, selection: $domain) }
                if let f = filters, f.users.count > 1 {
                    Picker("Sender", selection: $user) {
                        Text("Everyone").tag(Int?.none)
                        ForEach(f.users) { Text($0.email).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if let items, items.isEmpty {
                ContentUnavailableView(filtered ? "Nothing Matches" : "No Deliveries Yet", systemImage: "paperplane", description: Text(filtered ? "Try fewer filters." : "Mail sent from Wren shows here."))
            } else if let items {
                List {
                    ForEach(items) { e in
                        Button { open = LogTarget(kind: .delivery, id: e.id) } label: { DeliveryRow(entry: e) }
                            .buttonStyle(.plain)
                    }
                    if next != nil { MoreButton(loading: loadingMore) { await more() } }
                }
            } else {
                AdminLoading()
            }
        }
        .task(id: "\(panel.generation)|\(search)|\(event)|\(domain)|\(user ?? 0)") {
            guard await settle(search) else { return }
            let page = await panel.fetch(path(before: nil), as: AdminLogPage<AdminDeliveryEntry>.self)
            items = page?.items ?? items
            next = page?.nextBefore
        }
        .sheet(item: $open) { LogDetailSheet(panel: panel, target: $0) }
    }

    private var filtered: Bool { !search.isEmpty || !event.isEmpty || !domain.isEmpty || user != nil }

    private func path(before: Double?) -> String {
        "/delivery-log" + adminQuery(["q": search, "event": event, "domain": domain, "user": user.map { String($0) }, "before": before.flatMap { Int(exactly: $0.rounded(.towardZero)) }.map(String.init)])
    }

    private func more() async {
        guard let next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = await panel.fetch(path(before: next), as: AdminLogPage<AdminDeliveryEntry>.self) {
            items = (items ?? []) + page.items
            self.next = page.nextBefore
        }
    }
}

private struct DeliveryRow: View {
    let entry: AdminDeliveryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AdminBadge(text: entry.event, tone: AdminBadge.tone(entry.event))
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subject ?? "—").lineLimit(1)
                Text([entry.userEmail, entry.recipients.map { "→ \($0)" }].compactMap { $0 }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let d = entry.detail, !d.isEmpty {
                    Text((entry.providerName.map { "\($0): " } ?? "") + d).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            Text(adminDate(entry.createdAt)).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

private struct InboundLog: View {
    let panel: AdminPanel
    let filters: AdminLogFilters?
    @State private var search = ""
    @State private var status = ""
    @State private var domain = ""
    @State private var items: [AdminInboundEntry]?
    @State private var next: Double?
    @State private var loadingMore = false
    @State private var open: LogTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Sender, recipient, subject, reason", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Picker("Result", selection: $status) {
                    Text("All results").tag("")
                    Text("Problems only").tag("problems")
                    Divider()
                    ForEach(["accepted", "spam", "rejected", "duplicate", "error"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                if let f = filters, f.domains.count > 1 { DomainFilter(domains: f.domains, selection: $domain) }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if let items, items.isEmpty {
                let filtered = !search.isEmpty || !status.isEmpty || !domain.isEmpty
                ContentUnavailableView(filtered ? "Nothing Matches" : "No Inbound Mail Yet", systemImage: "tray.and.arrow.down", description: Text(filtered ? "Try fewer filters." : "Mail that arrives shows here."))
            } else if let items {
                List {
                    ForEach(items) { e in
                        Button { open = LogTarget(kind: .inbound, id: e.id) } label: { InboundRow(entry: e) }
                            .buttonStyle(.plain)
                    }
                    if next != nil { MoreButton(loading: loadingMore) { await more() } }
                }
            } else {
                AdminLoading()
            }
        }
        .task(id: "\(panel.generation)|\(search)|\(status)|\(domain)") {
            guard await settle(search) else { return }
            let page = await panel.fetch(path(before: nil), as: AdminLogPage<AdminInboundEntry>.self)
            items = page?.items ?? items
            next = page?.nextBefore
        }
        .sheet(item: $open) { LogDetailSheet(panel: panel, target: $0) }
    }

    private func path(before: Double?) -> String {
        "/inbound-log" + adminQuery(["q": search, "status": status, "domain": domain, "before": before.flatMap { Int(exactly: $0.rounded(.towardZero)) }.map(String.init)])
    }

    private func more() async {
        guard let next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = await panel.fetch(path(before: next), as: AdminLogPage<AdminInboundEntry>.self) {
            items = (items ?? []) + page.items
            self.next = page.nextBefore
        }
    }
}

private struct InboundRow: View {
    let entry: AdminInboundEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AdminBadge(text: entry.status, tone: AdminBadge.tone(entry.status))
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(subjectText(entry.subject)).lineLimit(1)
                Text("\(entry.mailFrom?.isEmpty == false ? entry.mailFrom! : "—") → \(entry.rcptTo ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let r = entry.reason, !r.isEmpty { Text(r).font(.caption).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(adminDate(entry.createdAt)).font(.caption).foregroundStyle(.secondary)
                Text(entry.providerName ?? entry.source ?? "").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

private struct DomainFilter: View {
    let domains: [String]
    @Binding var selection: String

    var body: some View {
        Picker("Domain", selection: $selection) {
            Text("All domains").tag("")
            ForEach(domains, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct MoreButton: View {
    let loading: Bool
    let load: () async -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(loading ? "Loading…" : "Load Older Entries") { Task { await load() } }
                .disabled(loading)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// One log entry: who, what, the timeline and the headers. Never the message itself.
private struct LogDetailSheet: View {
    let panel: AdminPanel
    let target: LogTarget
    @Environment(\.dismiss) private var dismiss
    @State private var delivery: AdminDeliveryDetail?
    @State private var inbound: AdminInboundDetail?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch target.kind {
                case .delivery:
                    if let d = delivery { DeliveryDetailView(d: d) } else { Section { ProgressView().frame(maxWidth: .infinity) } }
                case .inbound:
                    if let d = inbound { InboundDetailView(d: d) } else { Section { ProgressView().frame(maxWidth: .infinity) } }
                }
                if let headers = delivery?.headers ?? inbound?.headers, !headers.isEmpty {
                    Section {
                        ScrollView {
                            Text(headers)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 180)
                    } header: {
                        Text("Headers")
                    } footer: {
                        Text("Only the headers are shown. What the message says stays private to its mailbox.")
                    }
                }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    if delivery?.job?.canRetry == true {
                        Button("Retry Delivery") { retry() }.disabled(busy)
                    }
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 600)
        .task { await load() }
    }

    private func load() async {
        switch target.kind {
        case .delivery: delivery = await panel.fetch("/delivery-log/\(target.id)")
        case .inbound: inbound = await panel.fetch("/inbound-log/\(target.id)")
        }
    }

    private func retry() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await panel.send("POST", "/delivery-log/\(target.id)/retry")
                panel.notice = (text: "Queued again. It goes out on the queue’s next run.", link: nil)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct DeliveryDetailView: View {
    let d: AdminDeliveryDetail

    var body: some View {
        Section("Outgoing delivery") {
            LabeledContent("Subject", value: subjectText(d.job?.subject ?? d.entry.subject))
            LabeledContent("From", value: d.job?.mailFrom ?? d.entry.userEmail ?? "—")
            LabeledContent("To", value: d.job?.recipients?.joined(separator: ", ") ?? d.entry.recipients ?? "—")
            if let job = d.job {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        AdminBadge(text: job.status, tone: AdminBadge.tone(job.status))
                        Text("after \(job.attempts ?? 0) attempt\(job.attempts == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                }
                if let p = job.providerName {
                    LabeledContent("Provider", value: p + (job.providerMessageId.map { " · id \($0)" } ?? ""))
                }
                if let e = job.lastError {
                    LabeledContent("Last error") { Text(e).foregroundStyle(.red).textSelection(.enabled) }
                }
                if job.status == "queued", let at = job.nextAttemptAt {
                    LabeledContent("Next attempt", value: adminAgo(at))
                }
                if let kind = job.kind { LabeledContent("Kind", value: kind) }
            }
        }
        Section("Timeline") {
            ForEach(d.timeline) { t in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        AdminBadge(text: t.event, tone: AdminBadge.tone(t.event))
                        Text(adminDate(t.createdAt)).font(.caption).foregroundStyle(.secondary)
                        if let p = t.providerName { Text("via \(p)").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let detail = t.detail, !detail.isEmpty {
                        Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct InboundDetailView: View {
    let d: AdminInboundDetail

    var body: some View {
        Section("Incoming message") {
            LabeledContent("Result") {
                HStack(spacing: 6) {
                    AdminBadge(text: d.entry.status, tone: AdminBadge.tone(d.entry.status))
                    if let r = d.entry.reason { Text(r).foregroundStyle(.secondary) }
                }
            }
            LabeledContent("From", value: d.entry.mailFrom?.isEmpty == false ? d.entry.mailFrom! : "—")
            LabeledContent("To", value: d.entry.rcptTo ?? "—")
            LabeledContent("Subject", value: subjectText(d.entry.subject))
            LabeledContent("Arrived", value: "\(adminDate(d.entry.createdAt)) via \(d.entry.providerName ?? d.entry.source ?? "—")")
            if let del = d.delivered {
                LabeledContent("Delivered to", value: [del.mailbox, del.folder].compactMap { $0 }.joined(separator: " · "))
                if let score = del.spamScore { LabeledContent("Spam score", value: score.formatted()) }
                if let auth = del.authResults, !auth.isEmpty {
                    LabeledContent("Authentication") {
                        HStack(spacing: 4) {
                            ForEach(auth.keys.sorted(), id: \.self) { k in
                                let v = auth[k] ?? ""
                                AdminBadge(text: "\(k.uppercased()) \(v)", tone: v == "pass" ? .ok : v == "none" ? .plain : .warn)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Addresses Wren won't mail: they hard-bounced, reported spam, or an admin added them.
private struct SuppressedList: View {
    let panel: AdminPanel
    @State private var search = ""
    @State private var add = ""
    @State private var items: [AdminSuppression]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wren stops mailing an address that hard-bounces or marks a message as spam, which protects your sending reputation. Senders get a clear notice instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
            HStack {
                TextField("Find an address", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                TextField("Block an address", text: $add)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(block)
                Button("Block", action: block)
                    .disabled(!add.contains("@"))
            }
            .padding(10)
            if let items, items.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No Suppressed Addresses" : "Nothing Matches", systemImage: "nosign", description: Text("Addresses that bounce or report spam show here."))
            } else if let items {
                List(items) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.address).textSelection(.enabled)
                            HStack(spacing: 6) {
                                AdminBadge(text: Self.reason(s.reason), tone: s.reason == "bounce" ? .danger : s.reason == "complaint" ? .warn : .plain)
                                Text(adminAgo(s.createdAt)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let d = s.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Button("Remove") {
                            let path = s.address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s.address
                            panel.change("DELETE", "/suppressions/\(path)") { _ in (text: "\(s.address) can be mailed again.", link: nil) }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                AdminLoading()
            }
        }
        .task(id: "\(panel.generation)|\(search)") {
            guard await settle(search) else { return }
            items = await panel.fetch("/suppressions" + adminQuery(["q": search]), as: Items.self)?.items
        }
    }

    private func block() {
        let address = add.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { return }
        panel.change("POST", "/suppressions", ["address": .string(address)]) { _ in (text: "Wren won’t mail \(address).", link: nil) }
        add = ""
    }

    static func reason(_ r: String) -> String {
        switch r {
        case "bounce": "Hard bounce"
        case "complaint": "Marked as spam"
        case "manual": "Added by an admin"
        default: r
        }
    }

    private struct Items: Decodable { var items: [AdminSuppression] }
}

// MARK: DMARC

/// Admin → DMARC Reports: what receiving servers report about mail sent as your domains.
struct AdminDmarcPage: View {
    @Bindable var panel: AdminPanel
    @State private var days = 30
    @State private var domains: [AdminDmarcDomain]?
    @State private var reports: [AdminDmarcReport] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Receivers such as Gmail and Outlook report how much mail sent as your domains passed DMARC, and which servers send as you without passing.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Picker("Period", selection: $days) {
                        ForEach([7, 30, 90, 180], id: \.self) { Text("Last \($0) days").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let domains {
                    if domains.isEmpty && reports.isEmpty {
                        ContentUnavailableView(
                            "No Reports Yet", systemImage: "checkmark.shield",
                            description: Text("Each domain’s DMARC record asks receivers to send daily reports to postmaster at that domain. Wren reads them as they arrive, usually within a day of sending. They’re kept 180 days.")
                        )
                    } else {
                        if domains.isEmpty {
                            Text("No reports cover the last \(days) days. Choose a longer period to see older ones.").foregroundStyle(.secondary)
                        }
                        ForEach(domains) { DmarcDomainCard(d: $0) }
                        if !reports.isEmpty { recent }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .task(id: "\(panel.generation)|\(days)") {
            domains = await panel.fetch("/dmarc" + adminQuery(["days": String(days)]), as: Domains.self)?.domains
            reports = await panel.fetch("/dmarc/reports?limit=50", as: Reports.self)?.items ?? []
        }
    }

    private var recent: some View {
        GroupBox("Recent reports") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Receiver"); Text("Domain"); Text("Period"); Text("Messages"); Text("Passed")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                ForEach(reports) { r in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.org)
                            if let id = r.reportId { Text(id).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                        }
                        Text(r.domain).foregroundStyle(.secondary)
                        Text(Self.period(r.begin, r.end)).foregroundStyle(.secondary)
                        Text("\(r.messages)").monospacedDigit()
                        AdminBadge(text: dmarcPercent(r.passRate), tone: dmarcTone(r.passRate))
                    }
                }
            }
            .padding(4)
        }
    }

    static func period(_ begin: Double, _ end: Double) -> String {
        let f = { (ms: Double) in wrenDate(ms)?.formatted(date: .abbreviated, time: .omitted) ?? "—" }
        return "\(f(begin)) – \(f(end))"
    }

    private struct Domains: Decodable { var domains: [AdminDmarcDomain] }
    private struct Reports: Decodable { var items: [AdminDmarcReport] }
}

private func dmarcTone(_ r: Double?) -> AdminBadge.Tone {
    guard let r else { return .plain }
    return r >= 98 ? .ok : r >= 90 ? .warn : .danger
}

private func dmarcPercent(_ r: Double?) -> String {
    r.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "—"
}

private struct DmarcDomainCard: View {
    let d: AdminDmarcDomain

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(d.reports) report\(d.reports == 1 ? "" : "s") from \(d.reporters) receiver\(d.reporters == 1 ? "" : "s") · latest \(adminAgo(d.lastReportAt))")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 28) {
                    stat("Passed DMARC", dmarcPercent(d.passRate), color: color)
                    stat("Messages", "\(d.total)", sub: "\(d.failed) failed")
                    stat("DKIM aligned", dmarcPercent(d.dkimPassRate))
                    stat("SPF aligned", dmarcPercent(d.spfPassRate))
                }
                if d.total > 0 {
                    ProgressView(value: min(100, max(0, d.passRate ?? 0)), total: 100)
                        .tint(color)
                        .accessibilityLabel("Passed DMARC")
                }
                Text("Failing sources").font(.headline)
                if d.failingSources.isEmpty {
                    Text("Every reported message passed DMARC in this period.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Servers whose mail as \(d.domain) passed neither DKIM nor SPF. If you know one (a newsletter tool, a billing system), set it up to sign for your domain. If not, someone may be pretending to be you.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    sources
                }
            }
            .padding(6)
        } label: {
            HStack(spacing: 6) {
                Text(d.domain).font(.headline)
                if let p = d.policy { AdminBadge(text: "p=\(p)") }
            }
        }
    }

    private var color: Color {
        switch dmarcTone(d.passRate) {
        case .ok: .green
        case .warn: .orange
        case .danger: .red
        default: .secondary
        }
    }

    private func stat(_ title: String, _ value: String, sub: String? = nil, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color)
            if let sub { Text(sub).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    private var sources: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Source IP"); Text("Messages"); Text("From"); Text("Receiver did"); Text("Reported by")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            ForEach(d.failingSources) { s in
                GridRow {
                    Text(s.ip).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text("\(s.count)").monospacedDigit()
                    Text(s.headerFrom.isEmpty ? "—" : s.headerFrom.joined(separator: ", ")).foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        ForEach(s.dispositions, id: \.self) { x in
                            AdminBadge(text: x == "none" ? "delivered" : x, tone: x == "reject" ? .danger : x == "quarantine" ? .warn : .plain)
                        }
                    }
                    Text(s.reporters.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Audit log

/// Admin → Audit Log: sign-ins, admin changes, provider edits, forwarding changes (the latest 500).
struct AdminActivityPage: View {
    @Bindable var panel: AdminPanel
    @State private var filter = ""
    @State private var items: [AdminAuditEntry]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter events", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                Spacer()
            }
            .padding(10)
            if let items {
                let shown = filtered(items)
                if shown.isEmpty {
                    ContentUnavailableView("Nothing Matches", systemImage: "list.bullet.rectangle", description: Text(filter.isEmpty ? "Nothing has been logged yet." : "Try another word."))
                } else {
                    List(shown) { AuditRow(entry: $0) }
                }
            } else {
                AdminLoading()
            }
        }
        .task(id: panel.generation) {
            items = await panel.fetch("/audit", as: Items.self)?.items
        }
    }

    private func filtered(_ items: [AdminAuditEntry]) -> [AdminAuditEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return items }
        return items.filter { "\($0.action) \($0.target ?? "") \($0.userEmail ?? "")".lowercased().contains(f) }
    }

    private struct Items: Decodable { var items: [AdminAuditEntry] }
}

private struct AuditRow: View {
    let entry: AdminAuditEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                AdminBadge(text: entry.action, tone: tone)
                Text([entry.userEmail, entry.target, entry.ip].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let d = details { Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled) }
            }
            Spacer()
            if entry.viaApp {
                Image(systemName: "macwindow").foregroundStyle(.secondary).help("Done from an app’s admin panel")
                    .accessibilityLabel("From an app")
            }
            Text(adminDate(entry.createdAt)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private var tone: AdminBadge.Tone {
        entry.action.contains("failed") ? .danger : ["deleted", "disabled", "reset"].contains { entry.action.contains($0) } ? .warn : .plain
    }

    /// The entry's details, as "key: value" pairs.
    private var details: String? {
        guard let o = entry.details?.object, !o.isEmpty else { return nil }
        return o.keys.sorted().map { k in "\(k): \(Self.text(o[k]!))" }.joined(separator: " · ")
    }

    private static func text(_ j: JSON) -> String {
        switch j {
        case .string(let s): return s
        case .number(let n): return Int(exactly: n).map(String.init) ?? String(n)
        case .bool(let b): return b ? "yes" : "no"
        case .null: return "—"
        default:
            let data = (try? JSONEncoder().encode(j)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
