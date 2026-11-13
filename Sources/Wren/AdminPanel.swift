import AppKit
import SwiftUI
import WrenKit

/// The admin panel's state: which sign-in, how far unlocking has got, and what's loaded. The unlock itself (a
/// short-lived token) is in the sign-in's AdminClient, in memory only: never the keychain or the disk.
@MainActor
@Observable
final class AdminPanel {
    static let shared = AdminPanel()

    enum Stage: Equatable {
        /// Waiting for the account password.
        case password
        /// The password was right; waiting for a second step.
        case second(AdminChallenge)
        /// Waiting for the number to be typed in Wren on the web.
        case web(AdminChallenge, number: Int, page: URL?)
        case unlocked
    }

    enum Section: String, CaseIterable, Identifiable {
        case overview, users, invites, queue, activity
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .users: "Users"
            case .invites: "Invitations"
            case .queue: "Mail Queue"
            case .activity: "Activity"
            }
        }

        var icon: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .users: "person.2"
            case .invites: "envelope.open"
            case .queue: "tray.and.arrow.up"
            case .activity: "list.bullet.rectangle"
            }
        }
    }

    var loginId: String?
    var stage = Stage.password
    var role: String?
    var busy = false
    var error: String?
    /// Something that worked and has a link to hand on (a setup link, an invitation).
    var notice: (text: String, link: String?)?
    var section = Section.users
    var locksAt: Date?
    /// Where an emailed code went, once one was sent.
    var emailSentTo: String?

    var overview: AdminOverview?
    var users: [AdminUser] = []
    var search = ""
    var selectedUser: Int?
    var detail: AdminUserDetail?
    var invites: [AdminInvite] = []
    var queue: [AdminQueued] = []
    var queueStatus = ""
    var activity: [AdminAuditEntry] = []

    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var idleLock: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        // Lock when the Mac sleeps, its screen locks or another user takes over, and when Wren quits.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in AdminPanel.shared.lockAll() }
            }))
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in AdminPanel.shared.lockAll() }
        }))
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AdminPanel.shared.lockAll() }
        }))
    }

    /// The sign-ins whose person may open the admin panel.
    var logins: [Login] { MailStore.shared.logins.filter { $0.adminRole != nil } }

    var login: Login? { logins.first { $0.id == loginId } ?? logins.first }

    var isHelpdesk: Bool { role == "helpdesk" }

    /// Helpdesk staff do account support only: people and invitations.
    var sections: [Section] { isHelpdesk ? [.users, .invites] : Section.allCases }

    /// This Mac's name, for the approval request and the emailed code.
    private var device: String {
        "Wren for Mac on \(Host.current().localizedName ?? "a Mac")"
    }

    // MARK: Unlocking

    func start(password: String) {
        guard let login, !password.isEmpty else { return }
        run {
            let challenge = try await login.admin.start(password: password, device: self.device)
            self.role = challenge.role
            self.emailSentTo = nil
            self.stage = .second(challenge)
        }
    }

    func verify(_ challenge: AdminChallenge, step: AdminStep, code: String) {
        guard let login else { return }
        let code = code.filter { !$0.isWhitespace }
        guard !code.isEmpty else { return }
        run {
            if try await login.admin.verify(challenge, step: step, code: code) { await self.unlocked() }
        }
    }

    func sendEmailCode(_ challenge: AdminChallenge) {
        guard let login else { return }
        run { self.emailSentTo = try await login.admin.sendEmailCode(challenge) }
    }

    /// Ask for approval on the web, then check every two seconds until it's answered (or the challenge runs out).
    func approveOnWeb(_ challenge: AdminChallenge) {
        guard let login else { return }
        run {
            let (number, page) = try await login.admin.askWeb(challenge)
            self.stage = .web(challenge, number: number, page: page)
            self.waiting?.cancel()
            self.waiting = Task { [weak self] in await self?.waitForWeb(challenge, login: login) }
        }
    }

    private func waitForWeb(_ challenge: AdminChallenge, login: Login) async {
        while !Task.isCancelled, challenge.expiresAt > .now {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, case .web = stage else { return }
            do {
                if try await login.admin.verify(challenge, step: .web) {
                    await unlocked()
                    return
                }
            } catch {
                self.error = error.localizedDescription
                stage = .password
                return
            }
        }
        if case .web = stage {
            error = "The request ran out of time. Start again."
            stage = .password
        }
    }

    /// Back to choosing a second step (from waiting for the web).
    func back(to challenge: AdminChallenge) {
        waiting?.cancel()
        error = nil
        stage = .second(challenge)
    }

    func cancel() {
        waiting?.cancel()
        error = nil
        emailSentTo = nil
        stage = .password
    }

    private func unlocked() async {
        waiting?.cancel()
        error = nil
        stage = .unlocked
        if !sections.contains(section) { section = sections.first ?? .users }
        await load()
    }

    /// Lock now, here and on the server.
    func lock() {
        guard let login else { return }
        let admin = login.admin
        Task { await admin.lock() }
        lockedOut(message: nil)
    }

    /// A sign-in was removed or replaced: its unlock ends with it.
    func signedOut(_ gone: Login) {
        let admin = gone.admin
        Task { await admin.lock() }
        guard login === gone else { return }
        loginId = nil
        if stage != .password { lockedOut(message: nil) }
    }

    /// Open the panel for this sign-in, unless another one's is open or being unlocked.
    func show(_ login: Login) {
        if stage == .password { loginId = login.id }
    }

    /// Lock every sign-in's admin panel (sleep, screen lock, quitting).
    func lockAll() {
        for login in MailStore.shared.logins {
            let admin = login.admin
            Task { await admin.lock() }
        }
        if stage != .password { lockedOut(message: nil) }
    }

    /// Back to the password, forgetting what was shown.
    private func lockedOut(message: String?) {
        waiting?.cancel()
        idleLock?.cancel()
        stage = .password
        error = message
        notice = nil
        locksAt = nil
        overview = nil
        users = []
        detail = nil
        selectedUser = nil
        invites = []
        queue = []
        activity = []
    }

    /// Run an unlock step or an admin call: one at a time, with its error shown. Locks when the server says the unlock ended.
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch AdminError.locked {
                lockedOut(message: AdminError.locked.errorDescription)
            } catch {
                self.error = error.localizedDescription
            }
            await noteActivity()
        }
    }

    /// After each call: when it locks if nothing more is done, and a lock at that moment.
    private func noteActivity() async {
        guard stage == .unlocked, let login else { return }
        locksAt = await login.admin.locksAt
        idleLock?.cancel()
        guard let at = locksAt else { return }
        let admin = login.admin
        idleLock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow + 1)))
            let stillOpen = await admin.isUnlocked
            guard !Task.isCancelled, !stillOpen else { return }
            await admin.lock()
            self?.lockedOut(message: "The admin panel locked after 15 minutes without use.")
        }
    }

    // MARK: Loading

    func load() async {
        guard let login, stage == .unlocked else { return }
        let admin = login.admin
        do {
            switch section {
            case .overview: overview = try await admin.get("/overview")
            case .users: try await loadUsers()
            case .invites: invites = try await admin.get("/invites", as: Invites.self).invites
            case .queue:
                let query = queueStatus.isEmpty ? "" : "?status=\(queueStatus)"
                queue = try await admin.get("/outbox\(query)", as: Queue.self).items
            case .activity: activity = try await admin.get("/audit", as: Audit.self).items
            }
            error = nil
        } catch AdminError.locked {
            lockedOut(message: AdminError.locked.errorDescription)
        } catch {
            self.error = error.localizedDescription
        }
        await noteActivity()
    }

    private func loadUsers() async throws {
        guard let login else { return }
        let q = search.trimmingCharacters(in: .whitespaces)
        let query = q.isEmpty ? "" : "?q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
        users = try await login.admin.get("/users\(query)", as: Users.self).users
        if let selectedUser { try await loadDetail(selectedUser) }
    }

    func select(user id: Int?) {
        selectedUser = id
        detail = nil
        guard let id, let login else { return }
        let admin = login.admin
        run { self.detail = try await admin.get("/users/\(id)/detail") }
    }

    private func loadDetail(_ id: Int) async throws {
        guard let login else { return }
        detail = try await login.admin.get("/users/\(id)/detail")
    }

    // MARK: Changes

    /// A change, then the page loads again. `done` says what happened, when that's worth saying.
    func change(_ method: String, _ path: String, _ body: JSON? = nil, done: ((JSON) -> (text: String, link: String?)?)? = nil) {
        guard let login else { return }
        let admin = login.admin
        run {
            let reply = try await admin.send(method, path, body)
            if let note = done?(reply) { self.notice = note }
            await self.load()
        }
    }

    func deleteUser(_ id: Int) {
        guard let login else { return }
        let admin = login.admin
        run {
            try await admin.send("DELETE", "/users/\(id)")
            self.selectedUser = nil
            self.detail = nil
            await self.load()
        }
    }

    /// The web admin panel, for what this one doesn't do (domains, providers, settings, backups).
    func openOnWeb() {
        guard let login, let url = URL(string: "admin", relativeTo: login.client.server) else { return }
        NSWorkspace.shared.open(url)
    }

    private struct Users: Decodable { var users: [AdminUser] }
    private struct Invites: Decodable { var invites: [AdminInvite] }
    private struct Queue: Decodable { var items: [AdminQueued] }
    private struct Audit: Decodable { var items: [AdminAuditEntry] }
}

// MARK: - Window

/// Window → Admin Panel (⌥⌘A), for admins and helpdesk staff.
struct AdminWindow: View {
    @Environment(MailStore.self) private var store
    @State private var panel = AdminPanel.shared

    var body: some View {
        Group {
            if panel.logins.isEmpty {
                ContentUnavailableView(
                    "No Admin Access", systemImage: "lock.shield",
                    description: Text("None of the accounts in Wren can open the admin panel.")
                )
            } else if panel.stage == .unlocked {
                AdminUnlocked(panel: panel)
            } else {
                AdminUnlockView(panel: panel)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        // Closing the window locks it too.
        .onDisappear { panel.lock() }
    }
}

// MARK: Unlocking

struct AdminUnlockView: View {
    @Bindable var panel: AdminPanel
    @State private var password = ""
    @State private var code = ""
    @State private var step = AdminStep.totp

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Unlock the Admin Panel").font(.title2.bold())
            if panel.logins.count > 1 {
                Picker("Account", selection: Binding(get: { panel.login?.id }, set: { panel.loginId = $0; panel.cancel() })) {
                    ForEach(panel.logins) { Text($0.username).tag(Optional($0.id)) }
                }
                .frame(width: 320)
                .disabled(panel.stage != .password)
            }
            content
                .frame(width: 360)
            if let error = panel.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(panel.busy)
        .onChange(of: panel.stage) { _, stage in
            code = ""
            if case .second(let c) = stage, let first = c.steps.first, !c.steps.contains(step) { step = first }
            if stage == .unlocked { password = "" }
        }
    }

    @ViewBuilder private var content: some View {
        switch panel.stage {
        case .password: passwordStep
        case .second(let challenge): secondStep(challenge)
        case .web(let challenge, let number, let page): webStep(challenge, number: number, page: page)
        case .unlocked: EmptyView()
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your account password: the one you sign in to Wren on the web with, not this Mac’s app password. Then confirm it’s you with a second step.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Account password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { panel.start(password: password) }
            HStack {
                if panel.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Continue") { panel.start(password: password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
    }

    private func secondStep(_ challenge: AdminChallenge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if challenge.steps.count > 1 {
                Picker("Confirm with", selection: $step) {
                    ForEach(challenge.steps) { Text(Self.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch step {
            case .totp:
                Text("Enter the 6-digit code from your authenticator app, or one of your recovery codes.")
                    .foregroundStyle(.secondary)
                codeField(challenge, step: .totp)
            case .web:
                Text("Approve from Wren in a browser where you’re signed in with your 2-step code or a passkey. You’ll type a number this Mac shows.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Approve on the Web") { panel.approveOnWeb(challenge) }
                        .keyboardShortcut(.defaultAction)
                }
            case .email:
                if let sentTo = panel.emailSentTo {
                    Text("A code went to \(sentTo). It works once, for 10 minutes.")
                        .foregroundStyle(.secondary)
                    codeField(challenge, step: .email)
                } else {
                    Text("Wren emails a code to your recovery address, \(challenge.emailTo ?? "outside Wren"). Never to this mailbox: this Mac can already read that.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Send Code") { panel.sendEmailCode(challenge) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            Button("Start Over") { panel.cancel() }
                .buttonStyle(.link)
        }
        .onAppear { if !challenge.steps.contains(step), let first = challenge.steps.first { step = first } }
    }

    private func codeField(_ challenge: AdminChallenge, step: AdminStep) -> some View {
        HStack {
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .onSubmit { panel.verify(challenge, step: step, code: code) }
            Button("Unlock") { panel.verify(challenge, step: step, code: code) }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty)
        }
    }

    private func webStep(_ challenge: AdminChallenge, number: Int, page: URL?) -> some View {
        VStack(spacing: 14) {
            Text("Type this number in Wren on the web:")
                .foregroundStyle(.secondary)
            Text(String(number))
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("The number is \(number)")
            Text("Wren asks in any browser where you’re signed in. If you didn’t start this, choose “This wasn’t me” there.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…").foregroundStyle(.secondary)
            }
            HStack {
                Button("Use Another Step") { panel.back(to: challenge) }
                Spacer()
                if let page {
                    Button("Open in Browser") { NSWorkspace.shared.open(page) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    static func title(_ step: AdminStep) -> String {
        switch step {
        case .totp: "Authenticator"
        case .web: "Web Approval"
        case .email: "Email Code"
        }
    }
}

// MARK: Unlocked

struct AdminUnlocked: View {
    @Bindable var panel: AdminPanel

    var body: some View {
        NavigationSplitView {
            List(panel.sections, selection: Binding(get: { panel.section }, set: { if let s = $0 { panel.section = s } })) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let notice = panel.notice { NoticeBar(notice: notice) { panel.notice = nil } }
                if let error = panel.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: panel.section) { await panel.load() }
        .toolbar {
            ToolbarItemGroup {
                if let at = panel.locksAt {
                    Text("Locks at \(at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The admin panel locks after 15 minutes without use, and an hour after unlocking.")
                }
                Button { Task { await panel.load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                if !panel.isHelpdesk {
                    Button { panel.openOnWeb() } label: { Label("Open on the Web", systemImage: "safari") }
                        .help("Domains, providers, settings and backups are in the admin panel on the web.")
                }
                Button { panel.lock() } label: { Label("Lock", systemImage: "lock") }
                    .keyboardShortcut("l", modifiers: [.command, .control])
            }
        }
        .navigationTitle(panel.login.map { "Admin · \($0.username)" } ?? "Admin")
    }

    @ViewBuilder private var page: some View {
        switch panel.section {
        case .overview: AdminOverviewPage(panel: panel)
        case .users: AdminUsersPage(panel: panel)
        case .invites: AdminInvitesPage(panel: panel)
        case .queue: AdminQueuePage(panel: panel)
        case .activity: AdminActivityPage(panel: panel)
        }
    }
}

/// Something that worked, with a link to copy (a setup link or an invitation).
private struct NoticeBar: View {
    let notice: (text: String, link: String?)
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.text)
                if let link = notice.link {
                    Text(link)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let link = notice.link {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
        }
        .padding(10)
        .background(.green.opacity(0.08))
    }
}

/// Dates in Wren's admin API are milliseconds.
func adminDate(_ ms: Double?) -> String {
    guard let date = wrenDate(ms) else { return "—" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

func adminBytes(_ n: Double?) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n ?? 0), countStyle: .file)
}

// MARK: Overview

struct AdminOverviewPage: View {
    @Bindable var panel: AdminPanel

    var body: some View {
        if let o = panel.overview {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(o.warnings, id: \.self) { w in
                        Label(w.message, systemImage: w.level == "warn" ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(w.level == "warn" ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        tile("People", "\(o.users)", "\(o.activeUsers) active, \(o.suspendedUsers) suspended")
                        tile("Domains", "\(o.domains)", "\(o.verifiedDomains) verified")
                        tile("Received today", "\(o.received24h)", "\(o.spam24h) spam, \(o.rejected24h) rejected")
                        tile("Sent today", "\(o.sent24h)", "\(o.failed24h) failed")
                        tile("Waiting to send", "\(o.queued + o.sending)", o.sending > 0 ? "\(o.sending) sending now" : "In the queue")
                        tile("Failed sign-ins", "\(o.failedSignIns24h)", "Last 24 hours; \(o.newLocationSignIns7d) from new places this week")
                    }
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
                    Text("Wren \(o.version)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: Users

struct AdminUsersPage: View {
    @Bindable var panel: AdminPanel
    @State private var creating = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search", text: $panel.search)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await panel.load() } }
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .help("New User")
                        .accessibilityLabel("New User")
                        .disabled(panel.isHelpdesk)
                }
                .padding(8)
                List(panel.users, selection: Binding(get: { panel.selectedUser }, set: { panel.select(user: $0) })) { user in
                    UserRow(user: user).tag(user.id)
                }
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
            Group {
                if let detail = panel.detail {
                    AdminUserDetailView(panel: panel, detail: detail)
                } else if panel.selectedUser != nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("No One Selected", systemImage: "person.crop.circle", description: Text("Choose someone to see their account."))
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $creating) { NewUserSheet(panel: panel) }
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

private struct RoleBadge: View {
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
    case suspend, signOut, reset2fa, delete, releaseHold, revokeSession(String), role(String)

    var id: String {
        switch self {
        case .suspend: "suspend"
        case .signOut: "signOut"
        case .reset2fa: "reset2fa"
        case .delete: "delete"
        case .releaseHold: "releaseHold"
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

struct AdminUserDetailView: View {
    @Bindable var panel: AdminPanel
    let detail: AdminUserDetail
    @State private var confirming: Confirm?
    @State private var holdNote = ""
    @State private var placingHold = false

    private var u: AdminUserDetail.User { detail.user }
    private var path: String { "/users/\(u.id)" }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text(u.name).font(.title3.bold())
                        Text(u.email).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if u.status == "suspended" { Text("Suspended").foregroundStyle(.red) }
                }
                if !panel.isHelpdesk {
                    // Asks first: a role decides who can manage everyone's accounts.
                    Picker("Role", selection: Binding(get: { u.role }, set: { role in if role != u.role { confirming = .role(role) } })) {
                        Text("User").tag("user")
                        Text("Helpdesk").tag("helpdesk")
                        Text("Admin").tag("admin")
                        if u.role == "owner" || panel.role == "owner" { Text("Owner").tag("owner") }
                    }
                } else {
                    LabeledContent("Role", value: u.role.capitalized)
                }
                LabeledContent("Storage", value: "\(adminBytes(u.usedBytes)) of \(adminBytes(u.quotaBytes))")
                LabeledContent("Last sign-in", value: adminDate(u.lastLoginAt))
                LabeledContent("Created", value: adminDate(u.createdAt))
            }
            security
            sending
            if !panel.isHelpdesk { administration }
            sessions
            signIns
        }
        .formStyle(.grouped)
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { c in
            Button(button(c), role: c.isDestructive ? .destructive : nil) { perform(c) }
        } message: { c in
            Text(message(c))
        }
        .sheet(isPresented: $placingHold) { holdSheet }
    }

    private var security: some View {
        Section("Sign-in and security") {
            LabeledContent("2-step sign-in", value: u.totpEnabled == true ? "On" : "Off")
            LabeledContent("Passkeys", value: "\(u.passkeys ?? 0)")
            LabeledContent("Recovery email", value: u.recoveryEmail.map { "\($0)\(u.recoveryVerified == true ? "" : " (not confirmed)")" } ?? "None")
            if let until = u.lockedUntil {
                LabeledContent("Locked out until", value: adminDate(until))
                Button("Let Them Try Again Now") { panel.change("POST", "\(path)/unlock") }
            }
            HStack {
                Button(u.status == "suspended" ? "Reactivate" : "Suspend…") {
                    if u.status == "suspended" { panel.change("PUT", path, ["status": "active"]) } else { confirming = .suspend }
                }
                Button("Sign Out Everywhere…") { confirming = .signOut }
                if u.totpEnabled == true { Button("Reset 2-Step…") { confirming = .reset2fa } }
            }
            HStack {
                if u.recoveryEmail != nil {
                    Button("Email a Password Reset Link") {
                        panel.change("POST", "\(path)/reset-link") { r in (text: "A reset link went to \(r["sentTo"]?.string ?? "their recovery email").", link: nil) }
                    }
                }
                Button("Make a Sign-In Link") {
                    panel.change("POST", "\(path)/setup-link") { r in (text: "A one-time link to choose a new password. Give it to them privately.", link: r["url"]?.string) }
                }
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
                LabeledContent("Sent today", value: "\(u.sentToday ?? 0) of \(u.sendLimitPerDay.map { "\($0)" } ?? "no limit")")
                if !panel.isHelpdesk { Button("Pause Sending") { panel.change("POST", "\(path)/pause-sending") } }
            }
        }
    }

    private var administration: some View {
        Section("Administration") {
            if let apps = detail.mailApps {
                Toggle("Mail apps", isOn: Binding(get: { apps.allowed }, set: { on in panel.change("PUT", path, ["mailApps": .bool(on)]) }))
                    .disabled(!apps.enabled)
                    .help(apps.enabled ? "Whether they can use mail apps such as this one." : "Mail apps are off for everyone (Settings → Security on the web).")
            }
            if let hold = u.legalHold {
                LabeledContent("Legal hold since", value: adminDate(hold.since))
                if let note = hold.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Button("Release Legal Hold…") { confirming = .releaseHold }
            } else {
                Button("Place on Legal Hold…") { placingHold = true }
            }
            if u.role != "owner" {
                Button("Delete Account…", role: .destructive) { confirming = .delete }
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

    private var holdSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Place \(u.email) on legal hold?").font(.headline)
            Text("While it’s on, none of their mail is deleted for good (retention, Delete Forever, deleting the account). They aren’t told.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Note (case or reason)", text: $holdNote)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { placingHold = false }
                    .keyboardShortcut(.cancelAction)
                Button("Place Hold") {
                    panel.change("PUT", "\(path)/legal-hold", ["hold": true, "note": .string(holdNote)])
                    placingHold = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var title: String {
        guard let c = confirming else { return "" }
        switch c {
        case .suspend: return "Suspend \(u.email)?"
        case .signOut: return "Sign \(u.email) out everywhere?"
        case .reset2fa: return "Reset 2-step sign-in for \(u.email)?"
        case .delete: return "Delete \(u.email)?"
        case .releaseHold: return "Release the legal hold on \(u.email)?"
        case .revokeSession: return "Sign out this browser?"
        case .role(let role): return role == "user" ? "Make \(u.email) an ordinary user?" : "Make \(u.email) \(role == "admin" ? "an admin" : role == "owner" ? "an owner" : "helpdesk staff")?"
        }
    }

    private func button(_ c: Confirm) -> String {
        switch c {
        case .suspend: "Suspend"
        case .signOut, .revokeSession: "Sign Out"
        case .reset2fa: "Reset 2-Step"
        case .delete: "Delete Account"
        case .releaseHold: "Release Hold"
        case .role: "Change Role"
        }
    }

    private func message(_ c: Confirm) -> String {
        switch c {
        case .suspend: "They’re signed out at once and can’t sign in or use mail apps until reactivated. Their mail keeps arriving."
        case .signOut: "Every browser they’re signed in on is signed out. Mail apps keep working until their app passwords are revoked."
        case .reset2fa: "They sign in with only their password until they set up 2-step sign-in again. Do this only once you’re sure it’s them asking."
        case .delete: "Their mail, contacts and settings are deleted for good. This can’t be undone."
        case .releaseHold: "Their mail can be deleted again as usual: by retention, by them, or by deleting the account."
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
        case .delete: panel.deleteUser(u.id)
        case .releaseHold: panel.change("PUT", "\(path)/legal-hold", ["hold": false])
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

private struct NewUserSheet: View {
    @Bindable var panel: AdminPanel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var name = ""
    @State private var personal = ""
    @State private var role = "user"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New User").font(.headline)
            Form {
                TextField("Address", text: $email, prompt: Text("name@yourdomain.com"))
                TextField("Name", text: $name)
                TextField("Their current email", text: $personal, prompt: Text("Not at this domain"))
                Picker("Role", selection: $role) {
                    Text("User").tag("user")
                    Text("Helpdesk").tag("helpdesk")
                    Text("Admin").tag("admin")
                }
            }
            Text("They choose their own password from a one-time setup link, emailed to their current address and shown here to hand on. That address becomes their recovery email.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// The current address is needed: it's where the setup link goes and becomes their recovery email, so it
    /// can't be the new mailbox itself (they couldn't read it before choosing a password).
    private var ready: Bool {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        let current = personal.trimmingCharacters(in: .whitespaces).lowercased()
        return address.contains("@") && current.contains("@") && current != address && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() {
        let to = personal.trimmingCharacters(in: .whitespaces)
        let body: [String: JSON] = [
            "email": .string(email.trimmingCharacters(in: .whitespaces)),
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "role": .string(role),
            "setupEmail": .string(to),
        ]
        panel.change("POST", "/users", .object(body)) { r in (text: "Account created. A setup link went to \(to); you can also hand this one over.", link: r["setupUrl"]?.string) }
        dismiss()
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

// MARK: Mail queue

struct AdminQueuePage: View {
    @Bindable var panel: AdminPanel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $panel.queueStatus) {
                Text("All").tag("")
                Text("Waiting").tag("queued")
                Text("Failed").tag("failed")
                Text("Sent").tag("sent")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            .onChange(of: panel.queueStatus) { Task { await panel.load() } }
            if panel.queue.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "tray", description: Text("No messages with this status."))
            } else {
                List(panel.queue) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.subject?.isEmpty == false ? item.subject! : "(no subject)").lineLimit(1)
                            Text("\(item.from ?? "") → \(item.recipients.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let error = item.lastError, item.status != "sent" {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(item.status.capitalized).font(.caption.weight(.medium))
                            Text(adminDate(item.updatedAt)).font(.caption).foregroundStyle(.secondary)
                            if item.status == "failed" || item.status == "cancelled" {
                                Button("Retry") { panel.change("POST", "/outbox/\(item.id)/retry") }
                            } else if item.status == "queued" {
                                Button("Cancel") { panel.change("POST", "/outbox/\(item.id)/cancel") }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: Activity

struct AdminActivityPage: View {
    @Bindable var panel: AdminPanel

    var body: some View {
        List(panel.activity) { entry in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.action).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Text([entry.userEmail, entry.target, entry.ip].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if entry.viaApp {
                    Image(systemName: "macwindow").foregroundStyle(.secondary).help("Done from an app’s admin panel")
                        .accessibilityLabel("From an app")
                }
                Text(adminDate(entry.createdAt)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
