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
        case overview, users, invites, domains, addresses, providers, dmarc, queue, logs, settings, activity, system
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .users: "Users"
            case .invites: "Invitations"
            case .domains: "Domains"
            case .addresses: "Aliases & Groups"
            case .providers: "Providers"
            case .dmarc: "DMARC Reports"
            case .queue: "Mail Queue"
            case .logs: "Delivery Logs"
            case .settings: "Settings & Policies"
            case .activity: "Audit Log"
            case .system: "System & Backup"
            }
        }

        var icon: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .users: "person.2"
            case .invites: "envelope.open"
            case .domains: "globe"
            case .addresses: "at"
            case .providers: "powerplug"
            case .dmarc: "checkmark.shield"
            case .queue: "tray.and.arrow.up"
            case .logs: "list.bullet.rectangle.portrait"
            case .settings: "slider.horizontal.3"
            case .activity: "list.bullet.rectangle"
            case .system: "externaldrive"
            }
        }
    }

    struct Group: Identifiable {
        let title: String
        let sections: [Section]
        var id: String { title }
    }

    /// The sidebar's groups, as in the web admin panel.
    static let groups = [
        Group(title: "", sections: [.overview]),
        Group(title: "People", sections: [.users, .invites]),
        Group(title: "Mail", sections: [.domains, .addresses, .providers, .dmarc]),
        Group(title: "Delivery", sections: [.queue, .logs]),
        Group(title: "Server", sections: [.settings, .activity, .system]),
    ]

    var loginId: String?
    var stage = Stage.password
    var role: String?
    var busy = false
    var error: String?
    /// Something that worked and has a link to hand on (a setup link, an invitation).
    var notice: (text: String, link: String?)?
    var section = Section.overview
    var locksAt: Date?
    /// Where an emailed code went, once one was sent.
    var emailSentTo: String?

    var overview: AdminOverview?
    var users: [AdminUser] = []
    var search = ""
    var selectedUser: Int?
    /// The people picked in the list: one shows their page, several can be changed together.
    var picked: Set<Int> = []
    var detail: AdminUserDetail?
    var invites: [AdminInvite] = []
    /// Goes up after each change and on Reload: pages that load their own data reload when it does.
    var generation = 0
    /// What a page should open at, when another page sends you there (an alert, the setup checklist).
    var selectedDomain: Int?
    var settingsTab = AdminSettingsTab.general

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

    var isOwner: Bool { role == "owner" }

    /// The person signed in here (the panel's own account).
    func isMe(_ email: String) -> Bool { login?.username.lowercased() == email.lowercased() }

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
        picked = []
        selectedDomain = nil
        invites = []
        // Pages forget what they loaded.
        generation += 1
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
            // The other pages load their own.
            default: break
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
        // People deleted meanwhile drop out of what's picked.
        picked.formIntersection(users.map(\.id))
        if let selectedUser { try await loadDetail(selectedUser) }
    }

    /// Pick people in the list.
    func pick(_ ids: Set<Int>) {
        picked = ids
        if ids.count == 1 { select(user: ids.first) } else { selectedUser = nil; detail = nil }
    }

    func select(user id: Int?) {
        selectedUser = id
        picked = id.map { [$0] } ?? []
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

    /// Load everything again: this page's data and every page that loads its own.
    func reload() {
        generation += 1
        Task { await load() }
    }

    /// A change, then the page loads again. `done` says what happened, when that's worth saying.
    func change(_ method: String, _ path: String, _ body: JSON? = nil, done: ((JSON) -> (text: String, link: String?)?)? = nil) {
        guard let login else { return }
        let admin = login.admin
        run {
            let reply = try await admin.send(method, path, body)
            if let note = done?(reply) { self.notice = note }
            self.generation += 1
            await self.load()
        }
    }

    /// A change from a sheet, which shows its own errors: answers the reply, or throws. Pages reload after it,
    /// unless `reload` is false (after a restore, which ends the unlock: the page says so first).
    @discardableResult
    func send(_ method: String, _ path: String, _ body: JSON? = nil, reload: Bool = true) async throws -> JSON {
        guard let login else { throw AdminError.locked }
        do {
            let reply = try await login.admin.send(method, path, body)
            if reload { generation += 1 }
            await noteActivity()
            return reply
        } catch AdminError.locked {
            lockedOut(message: AdminError.locked.errorDescription)
            throw AdminError.locked
        }
    }

    /// Something for a page to show: nil when it couldn't be loaded (the error shows above the page).
    func fetch<T: Decodable>(_ path: String, as type: T.Type = T.self) async -> T? {
        guard let login, stage == .unlocked else { return nil }
        do {
            let value = try await login.admin.get(path, as: T.self)
            await noteActivity()
            return value
        } catch AdminError.locked {
            lockedOut(message: AdminError.locked.errorDescription)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
        return nil
    }

    func deleteUser(_ id: Int, transferTo: Int? = nil) {
        guard let login else { return }
        let admin = login.admin
        run {
            try await admin.send("DELETE", "/users/\(id)\(transferTo.map { "?transferTo=\($0)" } ?? "")")
            self.selectedUser = nil
            self.picked = []
            self.detail = nil
            self.generation += 1
            await self.load()
        }
    }

    /// Save a download (an export, a backup): asks where first, then downloads straight to that file.
    func download(_ path: String, suggested name: String) {
        guard let login else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = name
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let target = save.url else { return }
        let admin = login.admin
        run {
            let (file, _) = try await admin.download(path)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
            self.notice = (text: "Saved \(target.lastPathComponent).", link: nil)
        }
    }

    /// Send a file you choose as the request body (an export to restore). Answers the reply, or throws.
    func upload(_ path: String, file: URL, contentType: String, reload: Bool = true) async throws -> JSON {
        guard let login else { throw AdminError.locked }
        do {
            let reply = try await login.admin.upload(path, file: file, contentType: contentType)
            if reload { generation += 1 }
            return reply
        } catch AdminError.locked {
            lockedOut(message: AdminError.locked.errorDescription)
            throw AdminError.locked
        }
    }

    /// A link from the server (an alert's "Fix", a setup step): the page here that fixes it, else the web app.
    func open(link: String) {
        let parts = link.split(separator: "/").map(String.init)
        guard parts.first == "admin" else { return openOnWeb(link) }
        switch parts.dropFirst().first {
        case "users": section = .users; if let id = parts.dropFirst(2).first.flatMap(Int.init) { select(user: id) }
        case "domains": section = .domains; selectedDomain = parts.dropFirst(2).first.flatMap(Int.init)
        case "dmarc": section = .dmarc
        case "addresses": section = .addresses
        case "providers": section = .providers
        case "queue": section = .queue
        case "logs": section = .logs
        case "invites": section = .invites
        case "audit": section = .activity
        case "system": section = .system
        case "settings":
            section = .settings
            if let tab = parts.dropFirst(2).first.flatMap(AdminSettingsTab.init(rawValue:)) { settingsTab = tab }
        default: section = .overview
        }
    }

    /// A page of Wren on the web (your own settings, which the Mac doesn't do).
    func openOnWeb(_ path: String) {
        guard let login, let url = URL(string: path.hasPrefix("/") ? String(path.dropFirst()) : path, relativeTo: login.client.server) else { return }
        NSWorkspace.shared.open(url)
    }

    private struct Users: Decodable { var users: [AdminUser] }
    private struct Invites: Decodable { var invites: [AdminInvite] }
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
            List(selection: Binding(get: { panel.section }, set: { if let s = $0 { panel.section = s } })) {
                ForEach(AdminPanel.groups) { group in
                    let shown = group.sections.filter(panel.sections.contains)
                    if group.title.isEmpty {
                        ForEach(shown) { SidebarRow(section: $0).tag($0) }
                    } else if !shown.isEmpty {
                        Section(group.title) {
                            ForEach(shown) { SidebarRow(section: $0).tag($0) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                if let notice = panel.notice { NoticeBar(notice: notice) { panel.notice = nil } }
                if let error = panel.error {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { panel.error = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Close")
                    }
                    .padding(8)
                }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: panel.section) { await panel.load() }
        .onChange(of: panel.section) { panel.error = nil }
        .toolbar {
            ToolbarItemGroup {
                if let at = panel.locksAt {
                    Text("Locks at \(at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The admin panel locks after 15 minutes without use, and an hour after unlocking.")
                }
                Button { panel.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
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
        case .domains: AdminDomainsPage(panel: panel)
        case .addresses: AdminAddressesPage(panel: panel)
        case .providers: AdminProvidersPage(panel: panel)
        case .dmarc: AdminDmarcPage(panel: panel)
        case .queue: AdminQueuePage(panel: panel)
        case .logs: AdminLogsPage(panel: panel)
        case .settings: AdminSettingsPage(panel: panel)
        case .activity: AdminActivityPage(panel: panel)
        case .system: AdminSystemPage(panel: panel)
        }
    }
}

private struct SidebarRow: View {
    let section: AdminPanel.Section

    var body: some View {
        Label(section.title, systemImage: section.icon)
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
                Text(notice.text).fixedSize(horizontal: false, vertical: true)
                if let link = notice.link {
                    Text(link)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let link = notice.link { CopyButton(value: link, title: "Copy Link") }
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
        }
        .padding(10)
        .background(.green.opacity(0.08))
    }
}

// MARK: Shared pieces

/// Dates in Wren's admin API are milliseconds.
func adminDate(_ ms: Double?) -> String {
    guard let date = wrenDate(ms) else { return "—" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

/// "3 hours ago".
func adminAgo(_ ms: Double?) -> String {
    guard let date = wrenDate(ms) else { return "—" }
    return date.formatted(.relative(presentation: .named))
}

func adminBytes(_ n: Double?) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n ?? 0), countStyle: .file)
}

/// "87%", or a dash when there's nothing to count.
func adminPercent(_ n: Double?) -> String {
    n.map { "\(Int($0.rounded()))%" } ?? "—"
}

/// Copies a value to the clipboard.
struct CopyButton: View {
    let value: String
    var title = "Copy"

    var body: some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }
}

/// A value to copy into another app (a DNS record, a webhook URL).
struct CopyField: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                CopyButton(value: value)
                    .controlSize(.small)
                    .accessibilityLabel("Copy \(label)")
            }
        }
    }
}

/// A coloured word: ok, warn, danger or plain.
struct AdminBadge: View {
    enum Tone { case ok, warn, danger, accent, plain }
    let text: String
    var tone = Tone.plain

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .ok: .green
        case .warn: .orange
        case .danger: .red
        case .accent: .accentColor
        case .plain: .secondary
        }
    }

    /// The tone the web uses for a delivery or inbound status.
    static func tone(_ status: String) -> Tone {
        switch status {
        case "sent", "delivered", "accepted", "done", "ok": .ok
        case "queued", "sending", "running": .accent
        case "deferred", "spam", "delayed", "warn": .warn
        case "failed", "rejected", "error", "bounced", "complained": .danger
        default: .plain
        }
    }
}

/// A ✓, ✕ or · for a check that passed, failed or wasn't made.
struct CheckMark: View {
    let ok: Bool?
    var warnOnly = false

    var body: some View {
        Image(systemName: ok == nil ? "circle" : ok! ? "checkmark.circle.fill" : warnOnly ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok == nil ? Color.secondary : ok! ? Color.green : warnOnly ? Color.orange : Color.red)
            .accessibilityLabel(ok == nil ? "Not checked" : ok! ? "OK" : "Missing")
    }
}

/// A sheet's buttons, and its error when the server refused.
struct SheetButtons: View {
    var error: String?
    var busy = false
    let action: String
    var destructive = false
    var disabled = false
    let cancel: () -> Void
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(action, role: destructive ? .destructive : nil, action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled || busy)
            }
        }
    }
}

/// A change that can't be undone: typing `phrase` (an address, a word) unlocks the button.
struct TypedConfirmSheet: View {
    let title: String
    let message: String
    let phrase: String
    let action: String
    let perform: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type \(phrase) to confirm", text: $typed)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            SheetButtons(
                error: error, busy: busy, action: action, destructive: true,
                disabled: typed.trimmingCharacters(in: .whitespaces).lowercased() != phrase.lowercased(),
                cancel: { dismiss() },
                perform: {
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
            )
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// An empty page, or one still loading.
struct AdminLoading: View {
    var body: some View {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
