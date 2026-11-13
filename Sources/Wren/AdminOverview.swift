import Charts
import SwiftUI
import WrenKit

/// Admin → Overview: alerts, getting Wren ready, today's numbers and the last weeks of mail.
struct AdminOverviewPage: View {
    @Bindable var panel: AdminPanel
    @State private var alerts: AdminAlerts?
    @State private var checklist: AdminChecklist?
    @State private var showDone = false

    var body: some View {
        Group {
            if let o = panel.overview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        warnings(o)
                        if let open = alerts?.open, !open.isEmpty { AlertsBox(panel: panel, alerts: open) }
                        if let checklist { ChecklistBox(panel: panel, list: checklist, showDone: $showDone) }
                        tiles(o)
                        if o.series.count > 1 { MailChart(series: o.series) }
                        flagged(o)
                        Text("Wren \(o.version) · database \(adminBytes(o.databaseBytes)) · mail files \(adminBytes(o.fileBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            } else {
                AdminLoading()
            }
        }
        .task(id: panel.generation) {
            alerts = await panel.fetch("/alerts")
            checklist = await panel.fetch("/checklist")
        }
    }

    @ViewBuilder private func warnings(_ o: AdminOverview) -> some View {
        ForEach(o.warnings, id: \.self) { w in
            Label(w.message, systemImage: w.level == "warn" ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(w.level == "warn" ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tiles(_ o: AdminOverview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            tile("People", "\(o.users)", "\(o.activeUsers) active, \(o.suspendedUsers) suspended")
            tile("Domains", "\(o.domains)", "\(o.verifiedDomains) verified")
            tile("Received today", "\(o.received24h)", "\(o.spam24h) spam, \(o.rejected24h) rejected")
            tile("Sent today", "\(o.sent24h)", "\(o.failed24h) failed")
            tile("Waiting to send", "\(o.queued + o.sending)", o.sending > 0 ? "\(o.sending) sending now" : "In the queue")
            tile("Failed sign-ins", "\(o.failedSignIns24h)", "Last 24 hours; \(o.newLocationSignIns7d) from new places this week")
        }
    }

    @ViewBuilder private func flagged(_ o: AdminOverview) -> some View {
        if !o.flagged.isEmpty {
            Text("Sign-ins to look at").font(.headline)
            ForEach(o.flagged, id: \.self) { f in
                Button {
                    panel.section = .users
                    panel.select(user: f.id)
                } label: {
                    HStack {
                        Text(f.email)
                        Spacer()
                        if let n = f.failed, n > 0 { Text("\(n) failed").foregroundStyle(.red) }
                        if let n = f.newLocation, n > 0 { Text("\(n) new place\(n == 1 ? "" : "s")").foregroundStyle(.orange) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Open alerts: a failing provider, a stuck queue, full mailboxes, DNS changes.
private struct AlertsBox: View {
    let panel: AdminPanel
    let alerts: [AdminAlert]
    @State private var checking = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(alerts) { a in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: a.severity == "critical" ? "exclamationmark.octagon.fill" : a.severity == "warn" ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(a.severity == "critical" ? Color.red : a.severity == "warn" ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).fontWeight(.medium)
                            Text(a.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("Since \(adminAgo(a.createdAt))").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let link = a.link { Button("Fix…") { panel.open(link: link) } }
                        Button("Dismiss") {
                            panel.change("POST", "/alerts/\(a.id)/resolve") { _ in (text: "Alert dismissed. It comes back if the problem is still there at the next check.", link: nil) }
                        }
                        .help("It comes back if the problem is still there at the next check.")
                    }
                }
            }
            .padding(4)
        } label: {
            HStack {
                Label(alerts.count == 1 ? "1 open alert" : "\(alerts.count) open alerts", systemImage: "bell.badge")
                    .foregroundStyle(.red)
                Spacer()
                Button(checking ? "Checking…" : "Check Again") {
                    checking = true
                    Task {
                        _ = try? await panel.send("POST", "/alerts/check")
                        checking = false
                    }
                }
                .disabled(checking)
                .controlSize(.small)
            }
        }
    }
}

/// Getting Wren ready: domain, provider, DNS, a test message to yourself.
private struct ChecklistBox: View {
    let panel: AdminPanel
    let list: AdminChecklist
    @Binding var showDone: Bool
    @State private var running: String?

    var body: some View {
        let required = list.items.filter { $0.optional != true }
        let done = required.filter { $0.status == "done" }.count
        if list.complete && !showDone {
            Button { showDone = true } label: { Label("Setup complete", systemImage: "checkmark.circle.fill") }
                .buttonStyle(.link)
        } else {
            GroupBox(list.complete ? "Wren is ready" : "Get Wren ready: \(done) of \(required.count) required steps done") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(list.items) { item in row(item) }
                }
                .padding(4)
            }
            .task(id: list.items.contains { $0.id == "roundtrip" && $0.status == "pending" }) {
                // While the test message is on its way back, look again every few seconds.
                guard list.items.contains(where: { $0.id == "roundtrip" && $0.status == "pending" }) else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { panel.generation += 1 }
            }
        }
    }

    private func row(_ item: AdminChecklistItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(item.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium)
                    if item.optional == true { AdminBadge(text: "Optional") }
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action = item.action, item.status != "done" {
                Button(running == item.id ? "Working…" : action.label) { perform(item, action) }
                    .disabled(running != nil)
            }
        }
    }

    private func perform(_ item: AdminChecklistItem, _ action: AdminChecklistItem.Action) {
        if let api = action.api {
            running = item.id
            Task {
                defer { running = nil }
                do {
                    try await panel.send("POST", String(api.dropFirst("/api/admin".count)))
                    if item.id == "roundtrip" { panel.notice = (text: "Test message sent. Waiting for it to come back…", link: nil) }
                } catch {
                    panel.error = error.localizedDescription
                }
            }
        } else if let href = action.href {
            panel.open(link: href)
        }
    }

    @ViewBuilder private func icon(_ status: String) -> some View {
        switch status {
        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case "warn": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
        case "pending": ProgressView().controlSize(.small).accessibilityLabel("In progress")
        default: Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("To do")
        }
    }
}

/// Mail received and sent each day.
private struct MailChart: View {
    let series: [AdminOverview.Day]

    var body: some View {
        GroupBox("Last \(series.count) days") {
            Chart {
                ForEach(series, id: \.date) { day in
                    LineMark(x: .value("Day", wrenDate(day.date) ?? .now, unit: .day), y: .value("Messages", day.received))
                        .foregroundStyle(by: .value("Mail", "Received"))
                    LineMark(x: .value("Day", wrenDate(day.date) ?? .now, unit: .day), y: .value("Messages", day.sent))
                        .foregroundStyle(by: .value("Mail", "Sent"))
                }
            }
            .frame(height: 160)
            .padding(4)
            .accessibilityLabel("Mail received and sent each day")
        }
    }
}
