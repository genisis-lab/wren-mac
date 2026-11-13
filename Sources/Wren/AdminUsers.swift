import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WrenKit

// MARK: Users

/// Admin → Users: everyone's accounts. Pick one to see and change it, or several to change them together.
struct AdminUsersPage: View {
    @Bindable var panel: AdminPanel
    @State private var creating = false
    @State private var importing = false
    @State private var heldOnly = false

    private var shown: [AdminUser] { heldOnly ? panel.users.filter { $0.legalHold == true } : panel.users }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                bar
                List(shown, selection: Binding(get: { panel.picked }, set: { panel.pick($0) })) { user in
                    UserRow(user: user).tag(user.id)
                }
                Text("\(shown.count) \(shown.count == 1 ? "person" : "people")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
            Group {
                if panel.picked.count > 1 && !panel.isHelpdesk {
                    BulkView(panel: panel, ids: panel.picked)
                } else if let detail = panel.detail {
                    AdminUserDetailView(panel: panel, detail: detail)
                } else if panel.selectedUser != nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("No One Selected", systemImage: "person.crop.circle", description: Text("Choose someone to see their account. Pick several with ⌘ or ⇧ to change them together."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $creating) { NewUserSheet(panel: panel) }
        .sheet(isPresented: $importing) { ImportUsersSheet(panel: panel) }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $panel.search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await panel.load() } }
            if !panel.isHelpdesk {
                Menu {
                    Button("New User…") { creating = true }
                    Button("Import from a Spreadsheet…") { importing = true }
                    Divider()
                    Button("Export as a Spreadsheet…") { export() }
                    if panel.users.contains(where: { $0.legalHold == true }) {
                        Toggle("Only People on Legal Hold", isOn: $heldOnly)
                    }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    creating = true
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New User (more in the menu)")
                .accessibilityLabel("New User")
            }
        }
        .padding(8)
    }

    /// The list as a CSV file, with the same columns as the web's export.
    private func export() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "wren-users.csv"
        save.allowedContentTypes = [.commaSeparatedText]
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try AdminImport.export(shown).write(to: url, atomically: true, encoding: .utf8)
            panel.notice = (text: "Saved \(url.lastPathComponent).", link: nil)
        } catch {
            panel.error = error.localizedDescription
        }
    }
}

private struct UserRow: View {
    let user: AdminUser

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(user.name.isEmpty ? user.email : user.name).lineLimit(1)
                if user.role != "user" { RoleBadge(role: user.role) }
            }
            HStack(spacing: 6) {
                Text(user.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if user.isSuspended { Text("Suspended").font(.caption).foregroundStyle(.red) }
                if user.locked == true { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("Locked out") }
                if user.legalHold == true { Image(systemName: "building.columns").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Legal hold") }
            }
        }
        .padding(.vertical, 2)
    }
}

struct RoleBadge: View {
    let role: String

    var body: some View {
        Text(role.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}

/// A change to someone that needs a second look before it's made.
private enum Confirm: Identifiable {
    case suspend, signOut, reset2fa, releaseHold, passkeys, revokeSession(String), role(String)

    var id: String {
        switch self {
        case .suspend: "suspend"
        case .signOut: "signOut"
        case .reset2fa: "reset2fa"
        case .releaseHold: "releaseHold"
        case .passkeys: "passkeys"
        case .revokeSession(let id): "session \(id)"
        case .role(let role): "role \(role)"
        }
    }

    /// Taking something away; a new role only changes what they may do.
    var isDestructive: Bool {
        if case .role = self { return false }
        return true
    }
}

/// The sheets a person's page opens.
private enum UserSheet: String, Identifiable {
    case edit, password, rename, link, hold, mailHandling, delete
    var id: String { rawValue }
}

struct AdminUserDetailView: View {
    @Bindable var panel: AdminPanel
    let detail: AdminUserDetail
    @State private var confirming: Confirm?
    @State private var sheet: UserSheet?

    private var u: AdminUserDetail.User { detail.user }
    private var path: String { "/users/\(u.id)" }
    private var isMe: Bool { panel.isMe(u.email) }

    var body: some View {
        Form {
            summary
            security
            sending
            addresses
            if !panel.isHelpdesk {
                mailHandling
                exports
                administration
            }
            sessions
            signIns
        }
        .formStyle(.grouped)
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { c in
            Button(button(c), role: c.isDestructive ? .destructive : nil) { perform(c) }
        } message: { c in
            Text(message(c))
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .edit: EditUserSheet(panel: panel, user: u)
            case .password: PasswordSheet(panel: panel, user: u)
            case .rename: RenameSheet(panel: panel, user: u)
            case .link: SignInLinkSheet(panel: panel, user: u)
            case .hold: HoldSheet(panel: panel, user: u)
            case .mailHandling: MailHandlingSheet(panel: panel, user: u, value: detail.mailHandling ?? AdminMailHandling())
            case .delete: DeleteUserSheet(panel: panel, user: u)
            }
        }
    }

    private var summary: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(u.name).font(.title3.bold())
                    Text(u.email).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if u.status == "suspended" { Text("Suspended").foregroundStyle(.red) }
                Button("Edit…") { sheet = .edit }
            }
            if !panel.isHelpdesk && !isMe {
                // Asks first: a role decides who can manage everyone's accounts.
                Picker("Role", selection: Binding(get: { u.role }, set: { role in if role != u.role { confirming = .role(role) } })) {
                    Text("User").tag("user")
                    Text("Helpdesk").tag("helpdesk")
                    Text("Admin").tag("admin")
                    if u.role == "owner" || panel.isOwner { Text("Owner").tag("owner") }
                }
            } else {
                LabeledContent("Role", value: u.role.capitalized)
            }
            LabeledContent("Storage", value: "\(adminBytes(u.usedBytes)) of \(adminBytes(u.quotaBytes))\(u.customQuota == true ? "" : " (default)")")
            LabeledContent("Last sign-in", value: adminDate(u.lastLoginAt))
            LabeledContent("Created", value: adminDate(u.createdAt))
        }
    }

    private var security: some View {
        Section("Sign-in and security") {
            LabeledContent("2-step sign-in", value: u.totpEnabled == true ? "On" : "Off")
            LabeledContent("Passkeys", value: "\(u.passkeys ?? 0)")
            LabeledContent("Recovery email", value: u.recoveryEmail.map { "\($0)\(u.recoveryVerified == true ? "" : " (not confirmed)")" } ?? "None")
            LabeledContent("Password changed", value: adminDate(u.passwordChangedAt))
            if u.mustChangePassword == true {
                Text("They choose a new password at their next sign-in.").font(.caption).foregroundStyle(.secondary)
            }
            if let until = u.lockedUntil {
                LabeledContent("Locked out until", value: adminDate(until))
                Button("Let Them Try Again Now") { panel.change("POST", "\(path)/unlock") }
            }
            HStack {
                if !isMe && u.role != "owner" {
                    Button(u.status == "suspended" ? "Reactivate" : "Suspend…") {
                        if u.status == "suspended" { panel.change("PUT", path, ["status": "active"]) } else { confirming = .suspend }
                    }
                }
                Button("Sign Out Everywhere…") { confirming = .signOut }
                if u.totpEnabled == true { Button("Reset 2-Step…") { confirming = .reset2fa } }
                if (u.passkeys ?? 0) > 0 { Button("Remove Passkeys…") { confirming = .passkeys } }
            }
            HStack {
                Button("Set a Password…") { sheet = .password }
                Button(u.mustChangePassword == true ? "Don’t Require a New Password" : "Require a New Password") {
                    let on = u.mustChangePassword != true
                    panel.change("PUT", path, ["requirePasswordChange": .bool(on)]) { _ in
                        (text: on ? "They’ll choose a new password before they can carry on." : "They no longer have to choose a new password.", link: nil)
                    }
                }
            }
            HStack {
                if u.recoveryEmail != nil {
                    Button("Email a Password Reset Link") {
                        panel.change("POST", "\(path)/reset-link") { r in (text: "A reset link went to \(r["sentTo"]?.string ?? "their recovery email").", link: nil) }
                    }
                }
                Button("Send a Sign-In Link…") { sheet = .link }
            }
        }
    }

    private var sending: some View {
        Section("Sending") {
            if let paused = u.sendPausedAt {
                LabeledContent("Sending paused", value: adminDate(paused))
                if let reason = u.sendPausedReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if !panel.isHelpdesk { Button("Resume Sending") { panel.change("POST", "\(path)/resume-sending") } }
            } else {
                LabeledContent("Sent today", value: "\(u.sentToday ?? 0) of \(u.sendLimitPerDay.map { "\($0)" } ?? "no limit")\(u.customSendLimit == true ? "" : " (default)")")
                if !panel.isHelpdesk { Button("Pause Sending") { panel.change("POST", "\(path)/pause-sending") } }
            }
        }
    }

    @ViewBuilder private var addresses: some View {
        let shared = detail.shared ?? []
        if !detail.addresses.isEmpty || !shared.isEmpty {
            Section("Addresses") {
                ForEach(detail.addresses) { a in
                    LabeledContent(a.address, value: a.kind == "mailbox" ? "Their address" : a.kind.capitalized)
                }
                ForEach(shared) { b in
                    LabeledContent(b.email, value: b.canSend ? "Shared mailbox" : "Shared mailbox, read only")
                }
                if !panel.isHelpdesk {
                    Button("Change Address…") { sheet = .rename }
                }
            }
        }
    }

    private var mailHandling: some View {
        Section("Out of office and forwarding") {
            let h = detail.mailHandling ?? AdminMailHandling()
            LabeledContent("Automatic reply", value: h.vacation.enabled ? (h.vacation.endAt.map { "On until \(adminDate($0))" } ?? "On") : "Off")
            LabeledContent("Forwarding", value: h.forwarding.enabled ? "To \(h.forwarding.to)" : "Off")
            Button("Change…") { sheet = .mailHandling }
        }
    }

    private var exports: some View {
        Section("Mail export") {
            let jobs = detail.exports ?? []
            Text("All of their mail as one .mbox file, which Apple Mail, Gmail, Outlook and Thunderbird can import. They can see that an export was made.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(jobs) { job in ExportRow(panel: panel, user: u, job: job) }
            Button(jobs.contains(where: \.isRunning) ? "Exporting…" : "Export Mail") {
                panel.change("POST", "\(path)/export") { _ in (text: "Export started. It runs in the background.", link: nil) }
            }
            .disabled(jobs.contains(where: \.isRunning))
            // While an export runs, look again every few seconds. (On a row: a Section's modifiers reach each of its rows.)
            .task(id: jobs.filter(\.isRunning).map(\.id)) {
                guard jobs.contains(where: \.isRunning) else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { await panel.load() }
            }
        }
    }

    private var administration: some View {
        Section("Administration") {
            if let apps = detail.mailApps {
                Toggle("Mail apps", isOn: Binding(get: { apps.allowed }, set: { on in panel.change("PUT", path, ["mailApps": .bool(on)]) }))
                    .disabled(!apps.enabled)
                    .help(apps.enabled ? "Whether they can use mail apps such as this one." : "Mail apps are off for everyone (Settings & Policies → Security).")
                ForEach(apps.passwords ?? []) { p in
                    LabeledContent(p.name, value: p.lastUsedAt.map { "App password, used \(adminAgo($0))" } ?? "App password, not used yet")
                }
            }
            if let hold = u.legalHold {
                LabeledContent("Legal hold since", value: adminDate(hold.since))
                if let note = hold.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Button("Release Legal Hold…") { confirming = .releaseHold }
            } else {
                Button("Place on Legal Hold…") { sheet = .hold }
            }
            if u.role != "owner" && !isMe {
                Button("Delete Account…", role: .destructive) { sheet = .delete }
                    .disabled(u.legalHold != nil)
                    .help(u.legalHold != nil ? "Release the legal hold first." : "")
            }
        }
    }

    private var sessions: some View {
        Section("Signed in on") {
            if detail.sessions.isEmpty { Text("Nowhere right now").foregroundStyle(.secondary) }
            ForEach(detail.sessions) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.userAgent.map(Self.device) ?? "Unknown device")
                        Text("\(s.ip ?? "") · last seen \(adminDate(s.lastSeenAt))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out…") { confirming = .revokeSession(s.id) }
                }
            }
        }
    }

    private var signIns: some View {
        Section("Recent sign-ins") {
            ForEach(detail.signIns.prefix(20)) { s in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: s.ok ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(s.ok ? Color.green : Color.red)
                        .accessibilityLabel(s.ok ? "Succeeded" : "Failed")
                    VStack(alignment: .leading) {
                        Text(Self.method(s.method) + (s.reason.map { " · \(Self.reason($0))" } ?? ""))
                        Text([adminDate(s.at), s.ip, s.country].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if s.newLocation == true { Text("New place").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }

    private var title: String {
        guard let c = confirming else { return "" }
        switch c {
        case .suspend: return "Suspend \(u.email)?"
        case .signOut: return "Sign \(u.email) out everywhere?"
        case .reset2fa: return "Reset 2-step sign-in for \(u.email)?"
        case .releaseHold: return "Release the legal hold on \(u.email)?"
        case .passkeys: return "Remove \(u.email)’s passkeys?"
        case .revokeSession: return "Sign out this browser?"
        case .role(let role): return role == "user" ? "Make \(u.email) an ordinary user?" : "Make \(u.email) \(role == "admin" ? "an admin" : role == "owner" ? "an owner" : "helpdesk staff")?"
        }
    }

    private func button(_ c: Confirm) -> String {
        switch c {
        case .suspend: "Suspend"
        case .signOut, .revokeSession: "Sign Out"
        case .reset2fa: "Reset 2-Step"
        case .releaseHold: "Release Hold"
        case .passkeys: "Remove Passkeys"
        case .role: "Change Role"
        }
    }

    private func message(_ c: Confirm) -> String {
        switch c {
        case .suspend: "They’re signed out at once and can’t sign in or use mail apps until reactivated. Their mail keeps arriving."
        case .signOut: "Every browser they’re signed in on is signed out. Mail apps keep working until their app passwords are revoked."
        case .reset2fa: "They sign in with only their password until they set up 2-step sign-in again. Do this only once you’re sure it’s them asking."
        case .releaseHold: "Their mail can be deleted again as usual: by retention, by them, or by deleting the account."
        case .passkeys: "They’ll sign in with their password until they add new ones."
        case .revokeSession: "That browser is signed out; they can sign in again."
        case .role(let role):
            switch role {
            case "owner": "Owners can do everything an admin can, and make or remove other owners and admins."
            case "admin": "Admins can manage everyone’s accounts, domains, sending and server settings, and open the admin panel here after confirming it’s them."
            case "helpdesk": "Helpdesk staff can suspend, sign out and reset ordinary users, and invite people. Nothing else in the admin panel."
            default: "They can no longer open the admin panel."
            }
        }
    }

    private func perform(_ c: Confirm) {
        switch c {
        case .suspend: panel.change("PUT", path, ["status": "suspended"])
        case .signOut: panel.change("POST", "\(path)/signout")
        case .reset2fa: panel.change("POST", "\(path)/reset-2fa")
        case .releaseHold: panel.change("PUT", "\(path)/legal-hold", ["hold": false])
        case .passkeys: panel.change("DELETE", "\(path)/passkeys")
        case .revokeSession(let id): panel.change("DELETE", "\(path)/sessions/\(id)")
        case .role(let role): panel.change("PUT", path, ["role": .string(role)])
        }
        confirming = nil
    }

    static func method(_ m: String) -> String {
        switch m {
        case "password": "Password"
        case "passkey": "Passkey"
        case "password+2fa": "Password + 2-step"
        case "passkey+2fa": "Passkey + 2-step"
        case "link": "Reset or setup link"
        case "app-admin": "Admin unlock in an app"
        case "app-admin+2fa": "Admin unlock in an app + 2-step"
        case "app-admin+web": "Admin unlock in an app + web approval"
        case "app-admin+email": "Admin unlock in an app + emailed code"
        default: m
        }
    }

    static func reason(_ r: String) -> String {
        switch r {
        case "wrong_password": "wrong password"
        case "wrong_code": "wrong code"
        case "passkey_rejected": "passkey rejected"
        case "suspended": "account suspended"
        case "denied": "denied on the web"
        default: r
        }
    }

    /// "Safari on macOS" from a browser's user agent.
    static func device(_ ua: String) -> String {
        let browser = ua.contains("Edg/") ? "Edge" : ua.contains("Firefox/") ? "Firefox" : ua.contains("Chrome/") ? "Chrome" : ua.contains("Safari/") ? "Safari" : "A browser"
        let os = ua.contains("iPhone") ? "iPhone" : ua.contains("iPad") ? "iPad" : ua.contains("Android") ? "Android" : ua.contains("Mac OS X") ? "macOS" : ua.contains("Windows") ? "Windows" : ua.contains("Linux") ? "Linux" : ""
        return os.isEmpty ? browser : "\(browser) on \(os)"
    }
}

/// One mail export: its progress, and the file once it's ready.
private struct ExportRow: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    let job: AdminExportJob

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(adminAgo(job.createdAt))
                    AdminBadge(text: job.status == "done" ? "Ready" : job.status.capitalized, tone: job.status == "done" ? .ok : job.status == "failed" ? .danger : .plain)
                }
                Text(progress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if job.status == "done" {
                Button("Download…") {
                    let name = user.email.replacingOccurrences(of: "@", with: "-at-")
                    panel.download("/users/\(user.id)/export/\(job.id)/download", suggested: "\(name).mbox")
                }
            }
            Button { panel.change("DELETE", "/users/\(user.id)/export/\(job.id)") } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete this export")
        }
    }

    private var progress: String {
        var parts: [String] = []
        if let n = job.progress?.messages { parts.append("\(n) messages") }
        if let b = job.progress?.bytes, b > 0 { parts.append(adminBytes(b)) }
        if let e = job.error { parts.append(e) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Changing someone

/// Name, storage and sending limits.
private struct EditUserSheet: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var quota = ""
    @State private var limit = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(user.email)").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Mailbox quota (MB)", text: $quota, prompt: Text("Default"))
                Text("Using \(adminBytes(user.usedBytes)). Leave empty for the default.").font(.caption).foregroundStyle(.secondary)
                TextField("Messages sent per day", text: $limit, prompt: Text("Default"))
            }
            SheetButtons(error: error, busy: busy, action: "Save", disabled: name.trimmingCharacters(in: .whitespaces).isEmpty, cancel: { dismiss() }, perform: save)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = user.name
            quota = user.customQuota == true ? user.quotaBytes.flatMap { Int(exactly: ($0 / 1_048_576).rounded()) }.map(String.init) ?? "" : ""
            limit = user.customSendLimit == true ? user.sendLimitPerDay.map(String.init) ?? "" : ""
        }
    }

    private func save() {
        let q = quota.trimmingCharacters(in: .whitespaces), l = limit.trimmingCharacters(in: .whitespaces)
        guard q.isEmpty || Int(q) != nil, l.isEmpty || Int(l) != nil else {
            error = "Enter whole numbers, or leave them empty for the defaults."
            return
        }
        let body: JSON = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "quotaMb": Int(q).map { JSON.number(Double($0)) } ?? .null,
            "sendLimitPerDay": Int(l).map { JSON.number(Double($0)) } ?? .null,
        ]
        busy = true
        Task {
            defer { busy = false }
            do {
                try await panel.send("PUT", "/users/\(user.id)", body)
                await panel.load()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A password you choose for them, optionally only to get to "choose your own".
private struct PasswordSheet: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var mustChange = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set a password for \(user.email)").font(.headline)
            SecureField("New password", text: $password)
                .textFieldStyle(.roundedBorder)
            Toggle("Ask them to choose their own at next sign-in", isOn: $mustChange)
            Text("This password then only works once, to get to a “choose a new password” screen. Give it to them privately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SheetButtons(error: error, busy: busy, action: "Set Password", disabled: password.isEmpty, cancel: { dismiss() }) {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await panel.send("POST", "/users/\(user.id)/password", ["password": .string(password), "mustChange": .bool(mustChange)])
                        panel.notice = (text: "Password set for \(user.email).", link: nil)
                        await panel.load()
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

/// A new main address; the old one can stay as an alias.
private struct RenameSheet: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    @Environment(\.dismiss) private var dismiss
    @State private var domains: [AdminDomain] = []
    @State private var local = ""
    @State private var domain = ""
    @State private var keep = true
    @State private var busy = false
    @State private var error: String?

    private var next: String { "\(local.trimmingCharacters(in: .whitespaces).lowercased())@\(domain)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change \(user.email)’s address").font(.headline)
            Text("Their sign-in name and main address become the new one. Mail, contacts, settings and signed-in devices stay as they are, and they get a note in their inbox.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Name", text: $local).textFieldStyle(.roundedBorder)
                Text("@")
                Picker("Domain", selection: $domain) {
                    ForEach(domains.filter(\.enabled)) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Keep \(user.email) as an alias", isOn: $keep)
            Text("Mail to the old address still reaches them, and they can reply from it. Turn off to free the old address.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SheetButtons(error: error, busy: busy, action: "Change Address", disabled: local.isEmpty || domain.isEmpty || next == user.email.lowercased(), cancel: { dismiss() }) {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let r = try await panel.send("POST", "/users/\(user.id)/rename", ["email": .string(next), "keepOldAsAlias": .bool(keep)])
                        panel.notice = (text: "Address changed to \(r["email"]?.string ?? next).", link: nil)
                        await panel.load()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            let parts = user.email.split(separator: "@", maxSplits: 1).map(String.init)
            local = parts.first ?? ""
            domain = parts.count > 1 ? parts[1] : ""
            domains = await panel.fetch("/domains", as: DomainList.self)?.domains ?? []
        }
    }
}

struct DomainList: Decodable { var domains: [AdminDomain] }

/// A one-time link to choose a new password, shown here and emailed if you like.
private struct SignInLinkSheet: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    @Environment(\.dismiss) private var dismiss
    @State private var sendTo = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send \(user.email) a sign-in link").font(.headline)
            Text("A one-time link to choose a new password, for when they can’t sign in. It’s shown here to hand over too.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Email it to", text: $sendTo, prompt: Text("Optional: an address they can read now"))
                .textFieldStyle(.roundedBorder)
            SheetButtons(error: error, busy: busy, action: sendTo.isEmpty ? "Make Link" : "Send Link", cancel: { dismiss() }) {
                let to = sendTo.trimmingCharacters(in: .whitespaces)
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let r = try await panel.send("POST", "/users/\(user.id)/setup-link", to.isEmpty ? [:] : ["sendTo": .string(to)])
                        let sent = r["sentTo"]?.string
                        panel.notice = (text: sent.map { "A sign-in link went to \($0). You can also hand this one over privately." } ?? "A one-time sign-in link. Give it to them privately.", link: r["url"]?.string)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct HoldSheet: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Place \(user.email) on legal hold?").font(.headline)
            Text("While it’s on, none of their mail is deleted for good: Trash and Spam aren’t emptied, Delete Forever is refused, and the account can’t be deleted. They aren’t told.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Note (a case or ticket number)", text: $note)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Place Hold") {
                    panel.change("PUT", "/users/\(user.id)/legal-hold", ["hold": true, "note": .string(note)])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Out-of-office reply and forwarding, for someone who's away or has left.
private struct MailHandlingSheet: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    let value: AdminMailHandling
    @Environment(\.dismiss) private var dismiss
    @State private var h = AdminMailHandling()
    @State private var until = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Out of office and forwarding for \(user.email)").font(.headline)
            Text("They see and can change these in their own settings.").foregroundStyle(.secondary)
            Form {
                Section {
                    Toggle("Automatic reply", isOn: $h.vacation.enabled)
                    if h.vacation.enabled {
                        TextField("Subject", text: $h.vacation.subject, prompt: Text("Out of office"))
                        TextField("Message", text: $h.vacation.message, prompt: Text("I’m away until Monday. For anything urgent, write to …"), axis: .vertical)
                            .lineLimit(3...8)
                        Toggle("Only until a date", isOn: $until)
                        if until {
                            DatePicker("Until", selection: endDate, displayedComponents: .date)
                        }
                    }
                } footer: {
                    Text("Answers each sender once every few days.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Forward their mail", isOn: $h.forwarding.enabled)
                    if h.forwarding.enabled {
                        TextField("Forward to", text: $h.forwarding.to, prompt: Text("colleague@example.com"))
                        Picker("Their copy", selection: $h.forwarding.keep) {
                            Text("Keep in inbox").tag("inbox")
                            Text("Keep, marked read").tag("read")
                            Text("Archive it").tag("archive")
                            Text("Move to Trash").tag("trash")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons(error: error, busy: busy, action: "Save", disabled: h == value && until == (value.vacation.endAt != nil), cancel: { dismiss() }, perform: save)
        }
        .padding(20)
        .frame(width: 500, height: 520)
        .onAppear {
            h = value
            until = value.vacation.endAt != nil
        }
    }

    /// The end of the chosen day.
    private var endDate: Binding<Date> {
        Binding(
            get: { wrenDate(h.vacation.endAt) ?? Calendar.current.date(byAdding: .day, value: 7, to: .now)! },
            set: { day in
                let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
                h.vacation.endAt = end.timeIntervalSince1970 * 1000
            }
        )
    }

    private func save() {
        var out = h
        if !until || !out.vacation.enabled { out.vacation.endAt = nil }
        else if out.vacation.endAt == nil { out.vacation.endAt = (Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now).timeIntervalSince1970 * 1000 }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await panel.send("PUT", "/users/\(user.id)/mail-handling", out.json)
                await panel.load()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Delete someone for good, optionally handing their addresses to someone else first.
private struct DeleteUserSheet: View {
    let panel: AdminPanel
    let user: AdminUserDetail.User
    @Environment(\.dismiss) private var dismiss
    @State private var transferTo: Int?
    @State private var typed = ""

    private var others: [AdminUser] { panel.users.filter { $0.id != user.id && $0.status == "active" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(user.email)?").font(.headline)
            Text("This deletes the account and all of its mail. It can’t be undone; export their mail first if you might need it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Then send mail for their addresses to", selection: $transferTo) {
                Text("Nobody: the addresses stop working").tag(Int?.none)
                ForEach(others) { Text($0.email).tag(Optional($0.id)) }
            }
            Text("Their address and aliases become aliases of that account, so nothing sent to them bounces. Their catch-alls move too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type \(user.email) to confirm", text: $typed)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Permanently", role: .destructive) {
                    panel.deleteUser(user.id, transferTo: transferTo)
                    dismiss()
                }
                .disabled(typed.trimmingCharacters(in: .whitespaces).lowercased() != user.email.lowercased())
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: Several people

/// Changing several people at once.
private struct BulkView: View {
    let panel: AdminPanel
    let ids: Set<Int>
    @State private var results: [AdminBulkResult] = []
    @State private var asking: Action?
    @State private var value = ""
    @State private var deleting = false
    @State private var busy = false

    enum Action: String, Identifiable {
        case quota, sendLimit
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("\(ids.count) people selected") {
                HStack {
                    Button("Suspend") { run("suspend") }
                    Button("Reactivate") { run("activate") }
                    Button("Sign Out Everywhere") { run("signout") }
                }
                HStack {
                    Button("Require a New Password") { run("requirePasswordChange") }
                    Button("Set Quota…") { asking = .quota }
                    Button("Set Send Limit…") { asking = .sendLimit }
                }
                Button("Delete…", role: .destructive) { deleting = true }
                Text("Owners, people on legal hold and your own account are left out where a change doesn’t apply to them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(busy)
            if !results.isEmpty {
                Section("Result") {
                    let failed = results.filter { !$0.ok }
                    Text(failed.isEmpty ? "Done for all \(results.count)." : "Done for \(results.count - failed.count) of \(results.count).")
                    ForEach(failed, id: \.email) { r in
                        LabeledContent(r.email, value: r.error ?? "Not changed")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $asking) { action in
            VStack(alignment: .leading, spacing: 12) {
                Text(action == .quota ? "Mailbox quota for \(ids.count) people" : "Daily send limit for \(ids.count) people").font(.headline)
                TextField(action == .quota ? "Megabytes" : "Messages per day", text: $value, prompt: Text("Empty: the default"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { asking = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Set") {
                        let v = value.trimmingCharacters(in: .whitespaces)
                        run(action.rawValue, value: Int(v).map { JSON.number(Double($0)) } ?? .null)
                        asking = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!value.trimmingCharacters(in: .whitespaces).isEmpty && Int(value.trimmingCharacters(in: .whitespaces)) == nil)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
        .sheet(isPresented: $deleting) {
            TypedConfirmSheet(
                title: "Delete \(ids.count) people?",
                message: "Their accounts and all of their mail are deleted for good. This can’t be undone.",
                phrase: "delete \(ids.count) people",
                action: "Delete Permanently"
            ) {
                try await bulk("delete", value: nil)
            }
        }
        .onChange(of: ids) { results = [] }
    }

    private func run(_ action: String, value: JSON? = nil) {
        busy = true
        Task {
            defer { busy = false }
            do { try await bulk(action, value: value) } catch { panel.error = error.localizedDescription }
        }
    }

    private struct Results: Decodable { var results: [AdminBulkResult] }

    private func bulk(_ action: String, value: JSON?) async throws {
        var body: [String: JSON] = ["ids": .array(ids.sorted().map { .number(Double($0)) }), "action": .string(action)]
        if let value { body["value"] = value }
        let reply = try await panel.send("POST", "/users/bulk", .object(body))
        results = (try? JSONDecoder().decode(Results.self, from: JSONEncoder().encode(reply)))?.results ?? []
        await panel.load()
    }
}

// MARK: New people

private struct NewUserSheet: View {
    @Bindable var panel: AdminPanel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var name = ""
    @State private var withLink = true
    @State private var personal = ""
    @State private var password = ""
    @State private var role = "user"
    @State private var quota = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New User").font(.headline)
            Form {
                TextField("Address", text: $email, prompt: Text("name@yourdomain.com"))
                TextField("Name", text: $name)
                Picker("Password", selection: $withLink) {
                    Text("They choose it from a link").tag(true)
                    Text("I’ll set one").tag(false)
                }
                if withLink {
                    TextField("Their current email", text: $personal, prompt: Text("Not at this domain"))
                } else {
                    SecureField("Password", text: $password)
                }
                Picker("Role", selection: $role) {
                    Text("User").tag("user")
                    Text("Helpdesk").tag("helpdesk")
                    Text("Admin").tag("admin")
                    if panel.isOwner { Text("Owner").tag("owner") }
                }
                TextField("Mailbox quota (MB)", text: $quota, prompt: Text("Default"))
            }
            Text(withLink
                ? "A one-time setup link goes to their current address, and is shown here to hand on. That address becomes their recovery email."
                : "Give them the password privately. They can change it in Settings → Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SheetButtons(error: error, busy: busy, action: "Create", disabled: !ready, cancel: { dismiss() }, perform: create)
        }
        .padding(20)
        .frame(width: 460)
    }

    /// With a link, the current address is needed: it's where the link goes and becomes their recovery email, so
    /// it can't be the new mailbox itself (they couldn't read it before choosing a password).
    private var ready: Bool {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        let current = personal.trimmingCharacters(in: .whitespaces).lowercased()
        guard address.contains("@"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard quota.trimmingCharacters(in: .whitespaces).isEmpty || Int(quota.trimmingCharacters(in: .whitespaces)) != nil else { return false }
        return withLink ? current.contains("@") && current != address : !password.isEmpty
    }

    private func create() {
        let to = personal.trimmingCharacters(in: .whitespaces)
        var body: [String: JSON] = [
            "email": .string(email.trimmingCharacters(in: .whitespaces)),
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "role": .string(role),
        ]
        if withLink { body["setupEmail"] = .string(to) } else { body["password"] = .string(password) }
        if let q = Int(quota.trimmingCharacters(in: .whitespaces)) { body["quotaMb"] = .number(Double(q)) }
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await panel.send("POST", "/users", .object(body))
                panel.notice = withLink
                    ? (text: "Account created. A setup link went to \(to); you can also hand this one over.", link: r["setupUrl"]?.string)
                    : (text: "Account created for \(email.trimmingCharacters(in: .whitespaces)).", link: nil)
                await panel.load()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// People from a spreadsheet: check every row first, then create the good ones.
private struct ImportUsersSheet: View {
    let panel: AdminPanel
    @Environment(\.dismiss) private var dismiss
    @State private var fileName = ""
    @State private var rows: [JSON] = []
    @State private var checked: [AdminImportResult]?
    @State private var done: [AdminImportResult]?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import People").font(.headline)
            Text("A CSV file with a header line naming its columns: email and name, plus any of setup_email (where their setup link goes), password, role (user or admin), quota_mb and send_limit.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose File…") { choose() }
                Button("Save a Template…") { saveTemplate() }
                    .buttonStyle(.link)
                Spacer()
                if !fileName.isEmpty { Text("\(fileName): \(rows.count) rows").foregroundStyle(.secondary) }
            }
            results
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(done == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if done == nil, let checked {
                    let good = checked.filter(\.ok).count
                    Button("Create \(good) \(good == 1 ? "Account" : "Accounts")") { importGood() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(good == 0 || busy)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder private var results: some View {
        let list = done ?? checked ?? []
        if !list.isEmpty {
            List(list) { r in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: r.ok ? "checkmark.circle" : "xmark.circle").foregroundStyle(r.ok ? Color.green : Color.red)
                    Text("Row \(r.row)").foregroundStyle(.secondary).monospacedDigit()
                    Text(r.email)
                    Spacer()
                    if let e = r.error { Text(e).foregroundStyle(.red).font(.caption) }
                    if let link = r.setupUrl { CopyButton(value: link, title: "Copy Link").controlSize(.small) }
                }
            }
            .frame(minHeight: 200)
            if let done {
                let links = done.compactMap { r in r.setupUrl.map { "\(r.email)\t\($0)" } }
                HStack {
                    Text("Created \(done.filter(\.ok).count). Setup links went to the setup emails given.").foregroundStyle(.secondary)
                    Spacer()
                    if !links.isEmpty { CopyButton(value: links.joined(separator: "\n"), title: "Copy All Links") }
                }
            }
        } else {
            Spacer()
        }
    }

    private func choose() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard open.runModal() == .OK, let url = open.url else { return }
        error = nil
        checked = nil
        done = nil
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            error = "That file couldn’t be read as text."
            return
        }
        let (rows, warning) = AdminImport.rows(text)
        fileName = url.lastPathComponent
        self.rows = rows
        if let warning { error = warning; return }
        if rows.isEmpty { error = "There are no people in that file."; return }
        Task { checked = await send(rows, dryRun: true) }
    }

    private func importGood() {
        guard let checked else { return }
        let good = zip(rows, checked).filter { $0.1.ok }.map(\.0)
        Task {
            if let r = await send(good, dryRun: false) {
                done = r
                await panel.load()
            }
        }
    }

    private struct Results: Decodable { var results: [AdminImportResult] }

    /// The server takes 100 rows at a time; row numbers carry on across batches.
    private func send(_ list: [JSON], dryRun: Bool) async -> [AdminImportResult]? {
        busy = true
        defer { busy = false }
        var out: [AdminImportResult] = []
        do {
            for start in stride(from: 0, to: list.count, by: AdminImport.batch) {
                let batch = Array(list[start..<min(start + AdminImport.batch, list.count)])
                let reply = try await panel.send("POST", "/users/import", ["rows": .array(batch), "dryRun": .bool(dryRun)])
                let results = (try? JSONDecoder().decode(Results.self, from: JSONEncoder().encode(reply)))?.results ?? []
                out += results.map { r in var r = r; r.row += start; return r }
            }
            return out
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func saveTemplate() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "wren-users-template.csv"
        save.allowedContentTypes = [.commaSeparatedText]
        guard save.runModal() == .OK, let url = save.url else { return }
        try? AdminImport.template.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: Invitations

struct AdminInvitesPage: View {
    @Bindable var panel: AdminPanel
    @State private var inviting = false
    @State private var deleting: AdminInvite?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Invitations let someone make their own account.").foregroundStyle(.secondary)
                Spacer()
                Button("New Invitation…") { inviting = true }
            }
            .padding(10)
            List(panel.invites) { invite in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.email ?? "Any address").lineLimit(1)
                        Text(status(invite)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if invite.role != "user" { RoleBadge(role: invite.role) }
                    if invite.usedAt == nil {
                        if let to = invite.sentTo {
                            Button("Resend") {
                                panel.change("POST", "/invites/\(invite.id)/resend", ["sendTo": .string(to)]) { _ in (text: "Sent again to \(to).", link: nil) }
                            }
                        }
                        Button(role: .destructive) { deleting = invite } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete Invitation")
                    }
                }
            }
        }
        .sheet(isPresented: $inviting) { NewInviteSheet(panel: panel) }
        .confirmationDialog(
            "Delete the invitation\(deleting?.email.map { " for \($0)" } ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { invite in
            Button("Delete Invitation", role: .destructive) { panel.change("DELETE", "/invites/\(invite.id)") }
        } message: { _ in
            Text("Its link stops working. You can make a new invitation later.")
        }
    }

    private func status(_ i: AdminInvite) -> String {
        if let used = i.usedAt { return "Used \(adminDate(used))\(i.usedByEmail.map { " by \($0)" } ?? "")" }
        let expires = wrenDate(i.expiresAt) ?? .now
        if expires < .now { return "Expired \(adminDate(i.expiresAt))" }
        return "Expires \(adminDate(i.expiresAt))\(i.sentTo.map { " · sent to \($0)" } ?? "")"
    }
}

private struct NewInviteSheet: View {
    @Bindable var panel: AdminPanel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var sendTo = ""
    @State private var role = "user"
    @State private var days = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Invitation").font(.headline)
            Form {
                TextField("Address to create", text: $email, prompt: Text("Optional: they choose one"))
                TextField("Send it to", text: $sendTo, prompt: Text("Their current email (optional)"))
                if !panel.isHelpdesk {
                    Picker("Role", selection: $role) {
                        Text("User").tag("user")
                        Text("Admin").tag("admin")
                    }
                }
                Picker("Works for", selection: $days) {
                    ForEach([1, 7, 30], id: \.self) { Text("\($0) day\($0 == 1 ? "" : "s")").tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func create() {
        var body: [String: JSON] = ["role": .string(role), "days": .number(Double(days))]
        let mailbox = email.trimmingCharacters(in: .whitespaces)
        let to = sendTo.trimmingCharacters(in: .whitespaces)
        if !mailbox.isEmpty { body["email"] = .string(mailbox) }
        if !to.isEmpty { body["sendTo"] = .string(to) }
        panel.change("POST", "/invites", .object(body)) { r in
            (text: r["emailed"]?.bool == true ? "Invitation sent to \(to)." : "Invitation made. Send them the link.", link: r["url"]?.string)
        }
        dismiss()
    }
}
