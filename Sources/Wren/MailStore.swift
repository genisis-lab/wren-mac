import AppKit
import Network
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit
import WrenKit

/// A mailbox: which sign-in, which account in it (your own, or a shared mailbox), and which mailbox.
struct MailboxRef: Hashable {
    var login: String
    var account: String
    var mailbox: String

    /// Every sign-in's Inbox together, newest first.
    static let allInboxes = MailboxRef(login: "", account: "", mailbox: "all-inboxes")
}

struct NotConnected: LocalizedError {
    var errorDescription: String? { "Wren isn’t connected yet. Try again in a moment." }
}

/// One Wren sign-in (an email address and app password on a server): its connection, what it holds,
/// and the copy of its mail kept on this Mac.
@MainActor
@Observable
final class Login: Identifiable {
    let client: JMAPClient
    nonisolated let id: String
    let cache: MailCache
    var accounts: [Account] = []
    var mailboxes: [String: [Mailbox]] = [:]
    var identities: [String: [Identity]] = [:]
    /// Storage used and allowed in its own account, when the server says.
    var quota: Quota?
    /// A connection problem, shown quietly under the sidebar until the connection is back.
    var problem: String?
    @ObservationIgnored var listening: Task<Void, Never>?
    /// Inbox messages already notified about (nil until the first look, so mail that was already there isn't announced).
    @ObservationIgnored var announced: Set<String>?

    init(_ client: JMAPClient) {
        let key = Login.key(server: client.server, username: client.username)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wren/Cache")
        self.client = client
        id = key
        cache = MailCache(folder: folder.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key))
        // What it showed last time, until the server answers.
        if let state = cache.state {
            accounts = state.accounts
            mailboxes = state.mailboxes
            identities = state.identities
        }
    }

    nonisolated static func key(server: URL, username: String) -> String { "\(username) \(server.absoluteString)" }

    var username: String { client.username }

    /// Its own account (shared mailboxes have no storage limit, out-of-office reply or contacts of their own).
    var personal: Account? { accounts.first(where: \.isPersonal) }

    func ref(role: String, in account: String) -> MailboxRef? {
        mailboxes[account]?.first { $0.role == role }.map { MailboxRef(login: id, account: account, mailbox: $0.id) }
    }
}

/// A label being named in the label sheet.
struct LabelEdit: Identifiable {
    var login: String
    var account: String
    /// The label being renamed; nil for a new one.
    var label: String?
    var name = ""
    /// Conversations to give the new label once it's made.
    var labelling: Set<String> = []
    var id: String { "\(login) \(account) \(label ?? "new")" }
}

/// A message held for a few seconds after Send, so it can still be stopped.
struct PendingSend: Equatable {
    var submission: String
    var login: String
    var account: String
    /// The message as it was written, to open again.
    var draft: Draft
    var until: Date
}

/// Everything the windows show, and every change they make, for every sign-in.
@MainActor
@Observable
final class MailStore {
    /// The one store: the app delegate needs it too, for links and notifications.
    static let shared = MailStore()

    enum Phase { case starting, signedOut, signedIn }

    var phase = Phase.starting
    /// Shown on the sign-in screen, such as after the app password was revoked.
    var signInMessage: String?
    /// The sign-ins, in the order they were added.
    private(set) var logins: [Login] = []

    var selectedMailbox: MailboxRef?
    var selectedThreads: Set<String> = []
    var search = ""
    /// Only conversations with unread mail (until another mailbox is chosen).
    private(set) var unreadOnly = false
    /// Goes up when the list starts over with other rows. The list is made afresh then: changing a table row by row
    /// while its rows are still being measured is what AppKit logs as a reentrant operation.
    private(set) var listEpoch = 0
    private(set) var conversations: [Conversation] = []
    private(set) var total = 0
    private(set) var isLoading = false
    /// The open conversation's messages, oldest first, and where it lives.
    private(set) var thread: [Email] = []
    private(set) var threadId: String?
    private(set) var threadPlace: MailboxRef?
    /// The open conversation's messages that were unread when it opened (reading marks them read; they stay unfolded).
    private(set) var unreadWhenOpened: Set<String> = []
    /// Accounts ("login account") that refused to send: shared mailboxes you can read but not send from.
    private(set) var readOnly: Set<String> = []
    /// Encrypted messages as decrypted for reading (until Wren quits or the key is locked), so a reply can quote them.
    @ObservationIgnored var decrypted: [String: PGP.Opened] = [:]

    /// An action that failed.
    var alert: String?
    /// Conversations in the Trash waiting for "Delete Forever" to be confirmed.
    var confirmingDelete: Set<String>?
    /// The Trash or Junk mailbox waiting for "Empty" to be confirmed.
    var confirmingEmpty: MailboxRef?
    /// The label being named: a new one in an account, or one being renamed.
    var labelEditor: LabelEdit?
    /// A label waiting for "Delete" to be confirmed.
    var confirmingDeleteLabel: MailboxRef?
    /// A message just sent and still held for Undo Send.
    private(set) var pendingSend: PendingSend?
    /// The Scheduled Messages sheet is open.
    var showingScheduled = false

    @ObservationIgnored var undoManager: UndoManager?
    /// For windows opened from outside a window: mailto: links and notifications. Set by the main window.
    @ObservationIgnored var openWindow: OpenWindowAction? {
        didSet { openPending() }
    }
    /// mailto: links and files to attach that came before Wren was signed in and ready.
    @ObservationIgnored private var pendingLinks: [URL] = []
    /// What the widget was last given.
    @ObservationIgnored private var widgetMail: UnreadMail?
    /// A conversation to select once the mailbox being shown has loaded (from a notification).
    @ObservationIgnored private var openAfterLoad: String?
    @ObservationIgnored private var limit = 50
    @ObservationIgnored private var listGeneration = 0
    /// Where each row of the list lives (in All Inboxes, each comes from its own sign-in's Inbox).
    @ObservationIgnored private var rowPlaces: [String: MailboxRef] = [:]
    /// The reload running now; asks for another while it runs wait for it, then share one more.
    @ObservationIgnored private var reloading: Task<Void, Never>?
    @ObservationIgnored private var reloadAll = false
    @ObservationIgnored private var reloadLogins: Set<String> = []
    @ObservationIgnored private var reloadsAsked = 0
    @ObservationIgnored private var reloadsDone = 0
    /// Watches for the network coming back, to reconnect at once rather than when the old connection times out.
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var online: Bool?
    @ObservationIgnored private var lastReconnect = Date.distantPast

    init() {
        network.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up) }
        }
        network.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }
    }

    // MARK: Mailboxes

    func login(_ id: String?) -> Login? {
        logins.first { $0.id == id }
    }

    func mailbox(_ ref: MailboxRef?) -> Mailbox? {
        guard let ref else { return nil }
        if ref == .allInboxes {
            let all = inboxes.compactMap { mailbox($0) }
            return Mailbox(id: ref.mailbox, name: "All Inboxes", role: "inbox", sortOrder: 0, totalEmails: all.map(\.totalEmails).reduce(0, +), unreadEmails: all.map(\.unreadEmails).reduce(0, +))
        }
        return login(ref.login)?.mailboxes[ref.account]?.first { $0.id == ref.mailbox }
    }

    /// The mailbox with a role (inbox, drafts, sent…) in the same account as `ref`.
    func mailbox(role: String, in ref: MailboxRef) -> Mailbox? {
        login(ref.login)?.mailboxes[ref.account]?.first { $0.role == role }
    }

    func labels(in ref: MailboxRef) -> [Mailbox] {
        login(ref.login)?.mailboxes[ref.account]?.filter { $0.role == nil } ?? []
    }

    private func folders(in ref: MailboxRef) -> Set<String> {
        Set((login(ref.login)?.mailboxes[ref.account] ?? []).filter { $0.role != nil }.map(\.id))
    }

    var currentRole: String? { mailbox(selectedMailbox)?.role }

    /// Each sign-in's own Inbox.
    var inboxes: [MailboxRef] {
        logins.compactMap { l in l.personal.flatMap { l.ref(role: "inbox", in: $0.id) } }
    }

    /// Where a conversation in the list lives: the mailbox being shown, or in All Inboxes, its own Inbox.
    func place(of threadId: String) -> MailboxRef? {
        selectedMailbox == .allInboxes ? rowPlaces[threadId] : selectedMailbox
    }

    private func places(_ ids: Set<String>) -> [MailboxRef: Set<String>] {
        var out: [MailboxRef: Set<String>] = [:]
        for id in ids {
            if let place = place(of: id) { out[place, default: []].insert(id) }
        }
        return out
    }

    // MARK: Signing in

    /// The sign-ins saved on this Mac (their passwords are in the keychain).
    private func saved() -> [(server: URL, username: String)] {
        let defaults = UserDefaults.standard
        if let list = defaults.array(forKey: "logins") as? [[String: String]] {
            return list.compactMap { e in e["server"].flatMap(URL.init(string:)).flatMap { s in e["username"].map { (s, $0) } } }
        }
        // Wren 0.1 had one sign-in, kept here; it carries on as the first.
        guard let server = defaults.string(forKey: "server").flatMap(URL.init(string:)), let username = defaults.string(forKey: "username") else { return [] }
        return [(server, username)]
    }

    private func save() {
        UserDefaults.standard.set(logins.map { ["server": $0.client.server.absoluteString, "username": $0.username] }, forKey: "logins")
    }

    func restore() {
        guard phase == .starting else { return }
        for (server, username) in saved() {
            if let password = Keychain.read(username: username, server: server) { add(JMAPClient(server: server, username: username, password: password)) }
        }
        save()
        if logins.isEmpty { phase = .signedOut }
    }

    func signIn(server: URL, username: String, password: String) async throws {
        let client = JMAPClient(server: server, username: username, password: password)
        try await client.connect()
        try Keychain.save(password, username: username, server: server)
        // To fill in the form next time.
        UserDefaults.standard.set(server.absoluteString, forKey: "server")
        UserDefaults.standard.set(username, forKey: "username")
        signInMessage = nil
        add(client)
        save()
        // The moment to ask: they've just set up their mail.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Start using a sign-in (one signed in again replaces itself).
    func add(_ client: JMAPClient) {
        let login = Login(client)
        if let old = self.login(login.id) {
            old.listening?.cancel()
            logins.removeAll { $0 === old }
        }
        logins.append(login)
        phase = .signedIn
        // With a second sign-in, start from All Inboxes.
        if selectedMailbox == nil || (logins.count == 2 && selectedMailbox == inboxes.first) {
            selectedMailbox = nil
            showFirstMailbox()
        }
        updateDockBadge()
        login.listening = Task { [weak self] in await self?.listen(login) }
    }

    /// Sign out of one sign-in: its app password and the mail kept on this Mac are deleted.
    func remove(_ login: Login, message: String? = nil) {
        login.listening?.cancel()
        Keychain.delete(username: login.username, server: login.client.server)
        PGP.shared.forget(login)
        decrypted = [:]
        login.cache.delete()
        Spotlight.forget(login: login.id)
        logins.removeAll { $0 === login }
        save()
        undoManager?.removeAllActions()
        if selectedMailbox?.login == login.id || (selectedMailbox == .allInboxes && logins.count < 2) {
            selectedMailbox = nil
            showFirstMailbox()
        }
        updateDockBadge()
        guard logins.isEmpty else {
            if let message { alert = message }
            return
        }
        selectedThreads = []
        conversations = []
        total = 0
        thread = []
        threadId = nil
        threadPlace = nil
        search = ""
        NSApp.dockTile.badgeLabel = nil
        signInMessage = message
        phase = .signedOut
    }

    /// All Inboxes when there are several sign-ins, otherwise the Inbox. The list loads when the selection changes.
    private func showFirstMailbox() {
        guard selectedMailbox == nil else { return }
        selectedMailbox = logins.count > 1 ? .allInboxes : inboxes.first
    }

    /// Stay up to date: refresh whenever Wren says something changed, and reconnect when the stream ends or drops.
    private func listen(_ login: Login) async {
        var delay = 2.0
        while !Task.isCancelled {
            do {
                // Each connection fetches the session again, so shared mailboxes that come and go show up.
                let session = try await login.client.connect()
                login.accounts = session.mailAccounts
                for account in login.accounts { login.identities[account.id] = try await login.client.identities(account: account.id) }
                openPending()
                delay = 2
                // Wren sends the current state as soon as the stream opens, so this also loads everything.
                try await login.client.listen { [weak self] in await self?.refresh(login) }
            } catch JMAPError.unauthorized(_) {
                remove(login, message: "Wren didn’t accept the app password for \(login.username). If it was revoked, create a new one in Wren and sign in again.")
                return
            } catch {
                if Task.isCancelled { return }
                login.problem = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 60)
        }
    }

    private func networkChanged(_ up: Bool) {
        defer { online = up }
        // The first report is how things are at launch, not a change.
        if up, online == false { reconnect() }
    }

    /// Start every sign-in's connection over: after the Mac wakes or the network comes back, the old one is
    /// usually dead but would only time out minutes later, and a retry may be waiting up to a minute.
    func reconnect() {
        // Waking up often brings the network back too; once is enough.
        guard Date.now.timeIntervalSince(lastReconnect) > 5 else { return }
        lastReconnect = .now
        for login in logins {
            login.listening?.cancel()
            login.listening = Task { [weak self] in await self?.listen(login) }
        }
    }

    // MARK: Loading

    /// Load again: the mailboxes of one sign-in (or all), and the list and conversation when they show its mail.
    /// One reload runs at a time; asks that come in while it runs (an action, and the push that follows it) share
    /// the next one. Returns once a reload that started after the ask has finished.
    func refresh(_ only: Login? = nil) async {
        await refresh(logins: only.map { [$0.id] })
    }

    /// The sign-ins holding these places (each action reloads only the sign-ins it changed).
    private func refresh(_ places: some Sequence<MailboxRef>) async {
        await refresh(logins: Set(places.map(\.login)))
    }

    private func refresh(logins ids: Set<String>?) async {
        if let ids { reloadLogins.formUnion(ids) } else { reloadAll = true }
        reloadsAsked += 1
        let asked = reloadsAsked
        while reloadsDone < asked {
            if let running = reloading {
                await running.value
                continue
            }
            let all = reloadAll
            let only = reloadLogins
            let upTo = reloadsAsked
            reloadAll = false
            reloadLogins = []
            // Bookkeeping happens inside the task, so whoever wakes first after it sees it finished.
            let task = Task { [self] in
                await reload(all ? nil : logins.filter { only.contains($0.id) })
                reloadsDone = upTo
                reloading = nil
            }
            reloading = task
            await task.value
        }
    }

    private func reload(_ only: [Login]?) async {
        for login in only ?? logins {
            do {
                for account in login.accounts { login.mailboxes[account.id] = try await login.client.mailboxes(account: account.id) }
                if let personal = login.personal, personal.capabilities.contains(Capability.quota) { login.quota = try await login.client.quota(account: personal.id) }
                login.cache.state = .init(accounts: login.accounts, mailboxes: login.mailboxes, identities: login.identities)
                login.problem = nil
            } catch {
                login.problem = error.localizedDescription
            }
            await notifyNewMail(login)
        }
        updateDockBadge()
        let touched = only.map { Set($0.map(\.id)) }
        if let ref = selectedMailbox, ref != .allInboxes, login(ref.login)?.mailboxes[ref.account] != nil, mailbox(ref) == nil { selectedMailbox = nil }
        if selectedMailbox == nil {
            showFirstMailbox()
        } else if touched == nil || selectedMailbox == .allInboxes || touched?.contains(selectedMailbox?.login ?? "") == true {
            await loadList()
        }
        if let threadId, touched == nil || touched?.contains(threadPlace?.login ?? "") == true { await loadThread(threadId) }
    }

    /// Show the selected mailbox from the top: what it showed last time, then what's on the server.
    func showMailbox() async {
        selectedThreads = openAfterLoad.map { [$0] } ?? []
        openAfterLoad = nil
        conversations = []
        total = 0
        limit = 50
        rowPlaces = [:]
        unreadOnly = false
        if let ref = selectedMailbox, ref != .allInboxes, let cached = login(ref.login)?.cache.list(account: ref.account, mailbox: ref.mailbox) {
            conversations = cached.conversations
            total = cached.total
        }
        listEpoch += 1
        await loadList()
    }

    /// Show only unread mail, or everything again.
    func toggleUnreadOnly() async {
        unreadOnly.toggle()
        limit = 50
        await loadList()
    }

    func loadList() async {
        guard let ref = selectedMailbox else { return }
        listGeneration += 1
        let generation = listGeneration
        let unreadOnly = self.unreadOnly
        isLoading = true
        defer { if generation == listGeneration { isLoading = false } }
        var rows: [(conversation: Conversation, place: MailboxRef)] = []
        var total = 0
        var loaded = false
        for place in ref == .allInboxes ? inboxes : [ref] {
            guard let login = login(place.login) else { continue }
            do {
                let page = try await login.client.conversations(account: place.account, mailbox: place.mailbox, search: search, unreadOnly: unreadOnly, limit: limit)
                rows += page.list.map { ($0, place) }
                total += page.total
                loaded = true
                if search.isEmpty, !unreadOnly {
                    login.cache.saveList(.init(conversations: page.list, total: page.total), account: place.account, mailbox: place.mailbox)
                    Spotlight.index(page.list, in: place)
                }
            } catch {
                login.problem = error.localizedDescription
                // Offline: the list from last time.
                if search.isEmpty, !unreadOnly, let cached = login.cache.list(account: place.account, mailbox: place.mailbox) {
                    rows += cached.conversations.map { ($0, place) }
                    total += cached.total
                    loaded = true
                }
            }
        }
        // A newer load (another mailbox, a longer search) has started since, or nothing could be loaded at all.
        guard generation == listGeneration, loaded else { return }
        if ref == .allInboxes {
            rows.sort { ($0.conversation.email.receivedAt ?? .distantPast) > ($1.conversation.email.receivedAt ?? .distantPast) }
        }
        rows = Array(rows.prefix(limit))
        if unreadOnly {
            // What's selected stays in the list once reading it has marked it read, as in Mail.
            let listed = Set(rows.map(\.conversation.id))
            let kept = conversations.filter { selectedThreads.contains($0.id) && !listed.contains($0.id) }
            for row in kept {
                if let place = place(of: row.id) { rows.append((row, place)) }
            }
            if !kept.isEmpty { rows.sort { ($0.conversation.email.receivedAt ?? .distantPast) > ($1.conversation.email.receivedAt ?? .distantPast) } }
        }
        // Rows arriving in an empty list: nothing on screen to keep in place.
        if conversations.isEmpty, !rows.isEmpty { listEpoch += 1 }
        conversations = rows.map(\.conversation)
        rowPlaces = Dictionary(rows.map { ($0.conversation.id, $0.place) }, uniquingKeysWith: { a, _ in a })
        self.total = total
    }

    /// The next page. False when nothing more came (the server couldn't be reached), so the list offers to try again.
    @discardableResult
    func loadMore() async -> Bool {
        // A load already running (a refresh) finishes first; then this one asks for more.
        while isLoading { try? await Task.sleep(for: .milliseconds(100)) }
        guard conversations.count < total else { return true }
        let before = conversations.count
        limit += 50
        await loadList()
        return conversations.count > before
    }

    /// Open a conversation in the reader (nil closes it). Reading marks it read, as in Mail.
    func open(_ id: String?) async {
        threadId = id
        guard let id else {
            thread = []
            threadPlace = nil
            return
        }
        if thread.first?.threadId != id {
            thread = []
            unreadWhenOpened = []
            threadPlace = place(of: id)
            // Opened before: show it now, then bring it up to date.
            if let place = threadPlace, let cached = login(place.login)?.cache.thread(id) { thread = visible(cached, in: place) }
        }
        await loadThread(id)
        // Another conversation was chosen while this one loaded; it does its own reading.
        guard threadId == id else { return }
        let unread = thread.filter(\.isUnread)
        unreadWhenOpened.formUnion(unread.map(\.id))
        if !unread.isEmpty { await markRead(unread) }
    }

    private func loadThread(_ id: String) async {
        guard let place = threadPlace, let login = login(place.login) else { return }
        do {
            let emails = try await login.client.conversation(account: place.account, threadId: id)
            guard threadId == id else { return }
            login.cache.saveThread(emails, id: id)
            thread = visible(emails, in: place)
        } catch {
            if threadId == id { login.problem = error.localizedDescription }
        }
    }

    /// Messages in the Trash stay out of view, unless you're looking at the Trash.
    private func visible(_ emails: [Email], in place: MailboxRef) -> [Email] {
        let trash = mailbox(role: "trash", in: place)?.id
        let showTrash = mailbox(place)?.role == "trash"
        return emails.filter { email in showTrash || trash.map { email.mailboxIds[$0] != true } ?? true }
    }

    /// Bring up a conversation in a mailbox, such as new mail whose notification was clicked.
    func show(_ threadId: String, in ref: MailboxRef) {
        search = ""
        if selectedMailbox == ref || (selectedMailbox == .allInboxes && inboxes.contains(ref)) {
            selectedThreads = [threadId]
        } else {
            // Changing mailbox clears the selection when the list loads; this one is selected then.
            openAfterLoad = threadId
            selectedMailbox = ref
        }
        if let openWindow { openWindow(id: "main") }
        NSApp.activate()
    }

    /// A conversation chosen in Spotlight, in the mailbox it's in now: the Inbox if it's there.
    func showFound(_ id: String) async {
        guard let found = Spotlight.found(id), let login = login(found.login) else { return }
        guard let emails = try? await login.client.conversation(account: found.account, threadId: found.threadId) else { return }
        let folders = (login.mailboxes[found.account] ?? []).filter { $0.role != nil }
        let newest = emails.max { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) }
        let inbox = folders.first { folder in folder.role == "inbox" && emails.contains { $0.mailboxIds[folder.id] == true } }
        // Deleted since it was seen.
        guard let here = inbox ?? folders.first(where: { newest?.mailboxIds[$0.id] == true }) else { return Spotlight.forget(id) }
        show(found.threadId, in: MailboxRef(login: login.id, account: found.account, mailbox: here.id))
    }

    /// Whether the first sign-in is connected (or has what was kept from last time), waiting up to 10 seconds; for
    /// Shortcuts, which can launch Wren before its window has started the sign-ins.
    func ready() async -> Bool {
        restore()
        for _ in 0..<50 {
            if let login = logins.first, let personal = login.personal, login.identities[personal.id] != nil, login.mailboxes[personal.id] != nil {
                return true
            }
            if phase == .signedOut { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// A folder of the first sign-in's own account, or All Inboxes for the Inbox when there are several (Shortcuts).
    func select(role: String) {
        if role == "inbox", logins.count > 1 {
            selectedMailbox = .allInboxes
        } else if let login = logins.first, let personal = login.personal, let ref = login.ref(role: role, in: personal.id) {
            selectedMailbox = ref
        }
        if let openWindow { openWindow(id: "main") }
        NSApp.activate()
    }

    // MARK: Changing mail

    /// The messages an action on these conversations applies to: the ones in the mailbox each is shown from.
    private func targets(_ ids: Set<String>, in place: MailboxRef) async throws -> [Email] {
        guard let login = login(place.login) else { throw NotConnected() }
        return try await login.client.members(account: place.account, threadIds: Array(ids)).filter { $0.mailboxIds[place.mailbox] == true }
    }

    private func update(_ emails: [Email], in place: MailboxRef, _ patch: (Email) -> JSON) async throws {
        guard let login = login(place.login) else { throw NotConnected() }
        try await login.client.update(account: place.account, Dictionary(emails.map { ($0.id, patch($0)) }, uniquingKeysWith: { a, _ in a }))
    }

    func archive(_ ids: Set<String>, in place: MailboxRef? = nil) async {
        await move(ids, in: place, to: "archive", actionName: "Archive")
    }

    /// To the Trash; in the Trash, delete for good after asking.
    func trash(_ ids: Set<String>) async {
        if currentRole == "trash" { confirmingDelete = ids } else { await move(ids, to: "trash", actionName: "Move to Trash") }
    }

    /// To Spam; in Spam, back to the Inbox. Wren learns from both.
    func junk(_ ids: Set<String>) async {
        if currentRole == "junk" { await move(ids, to: "inbox", actionName: "Not Junk") } else { await move(ids, to: "junk", actionName: "Move to Junk") }
    }

    func moveToInbox(_ ids: Set<String>) async {
        await move(ids, to: "inbox", actionName: "Move to Inbox")
    }

    /// The folders conversations can be moved to from Move to: Inbox, Archive, Junk and Trash, less the one they're in.
    /// Drafts and Sent keep their own (Trash only).
    var moveTargets: [String] {
        guard let role = currentRole, !["drafts", "sent"].contains(role) else { return [] }
        return ["inbox", "archive", "junk", "trash"].filter { $0 != role }
    }

    /// Whether Move to Inbox is the way back from here (Archive, Trash and Snoozed; Junk has Not Junk).
    var canMoveToInbox: Bool { ["archive", "trash", "snoozed"].contains(currentRole ?? "") }

    static func folderName(_ role: String) -> String {
        switch role {
        case "inbox": "Inbox"
        case "archive": "Archive"
        case "junk": "Junk"
        case "trash": "Trash"
        default: role.capitalized
        }
    }

    /// To a folder chosen in Move to.
    func move(_ ids: Set<String>, toFolder role: String) async {
        if role == "trash" { return await trash(ids) }
        await move(ids, to: role, actionName: "Move to \(Self.folderName(role))")
    }

    /// Conversations from where they're shown (or from `only`, for a notification) to the folder with this role.
    private func move(_ ids: Set<String>, in only: MailboxRef? = nil, to role: String, actionName: String) async {
        var moves: [(place: MailboxRef, ids: Set<String>, target: String)] = []
        for (place, ids) in only.map({ [$0: ids] }) ?? places(ids) {
            if let target = mailbox(role: role, in: place), target.id != place.mailbox { moves.append((place, ids, target.id)) }
        }
        guard !moves.isEmpty else { return }
        removeFromList(Set(moves.flatMap { $0.ids }))
        var moved: [(emails: [Email], place: MailboxRef)] = []
        do {
            for move in moves {
                let folders = folders(in: move.place)
                let emails = try await targets(move.ids, in: move.place)
                try await update(emails, in: move.place) { Patch.move($0, to: move.target, folders: folders) }
                moved.append((emails, move.place))
            }
        } catch {
            alert = error.localizedDescription
        }
        if !moved.isEmpty {
            let done = moved
            undoManager?.registerUndo(withTarget: self) { store in
                Task { await store.putBack(done) }
            }
            undoManager?.setActionName(actionName)
        }
        await refresh(moves.map(\.place))
    }

    /// Undo a move: back where each message was (snoozed ones come back to the Inbox).
    private func putBack(_ moved: [(emails: [Email], place: MailboxRef)]) async {
        do {
            for (emails, place) in moved {
                guard let inbox = mailbox(role: "inbox", in: place) else { continue }
                let folders = folders(in: place)
                let snoozed = mailbox(role: "snoozed", in: place)?.id
                try await update(emails, in: place) { e in
                    let wasSnoozed = snoozed.map { e.mailboxIds[$0] == true } ?? false
                    return wasSnoozed ? Patch.move(e, to: inbox.id, folders: folders) : Patch.restore(e)
                }
            }
        } catch {
            alert = error.localizedDescription
        }
        await refresh(moved.map(\.place))
    }

    func deleteForever(_ ids: Set<String>) async {
        let groups = places(ids)
        removeFromList(ids)
        do {
            for (place, ids) in groups {
                try await login(place.login)?.client.destroy(account: place.account, ids: targets(ids, in: place).map(\.id))
            }
        } catch {
            alert = error.localizedDescription
        }
        await refresh(groups.keys)
    }

    func setRead(_ ids: Set<String>, _ read: Bool, in only: MailboxRef? = nil) async {
        updateRows(ids) { $0.keywords["$seen"] = read ? true : nil }
        let groups = only.map { [$0: ids] } ?? places(ids)
        do {
            for (place, ids) in groups {
                let emails = try await targets(ids, in: place)
                // Marking unread marks the newest message, as Mail does; marking read covers the whole conversation.
                let chosen = read ? emails.filter(\.isUnread) : Dictionary(grouping: emails, by: \.threadId).values.compactMap { $0.max { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) } }
                try await update(chosen, in: place) { _ in Patch.keyword("$seen", read) }
            }
        } catch {
            alert = error.localizedDescription
        }
        await refresh(groups.keys)
    }

    private func markRead(_ emails: [Email]) async {
        guard let place = threadPlace else { return }
        let ids = Set(emails.map(\.id))
        updateRows(Set(emails.map(\.threadId))) { $0.keywords["$seen"] = true }
        for i in thread.indices where ids.contains(thread[i].id) { thread[i].keywords["$seen"] = true }
        do {
            try await update(emails, in: place) { _ in Patch.keyword("$seen", true) }
        } catch {
            login(place.login)?.problem = error.localizedDescription
        }
    }

    func toggleFlag(_ ids: Set<String>) async {
        let rows = conversations.filter { ids.contains($0.id) }
        let flag = !rows.allSatisfy(\.email.isFlagged)
        updateRows(ids) { $0.keywords["$flagged"] = flag ? true : nil }
        let groups = places(ids)
        do {
            for (place, ids) in groups {
                try await update(rows.filter { ids.contains($0.id) }.map(\.email), in: place) { _ in Patch.keyword("$flagged", flag) }
            }
        } catch {
            alert = error.localizedDescription
        }
        await refresh(groups.keys)
    }

    /// Whether every selected conversation is flagged (so Flag reads Unflag).
    var selectionIsFlagged: Bool {
        let rows = conversations.filter { selectedThreads.contains($0.id) }
        return !rows.isEmpty && rows.allSatisfy(\.email.isFlagged)
    }

    /// Snoozing is for the Inbox and Archive, in accounts whose server supports it.
    var canSnooze: Bool {
        guard currentRole == "inbox" || currentRole == "archive", let ref = selectedMailbox else { return false }
        let refs = ref == .allInboxes ? inboxes : [ref]
        return !refs.isEmpty && refs.allSatisfy { r in login(r.login)?.accounts.first { $0.id == r.account }?.canSnooze == true }
    }

    func snooze(_ ids: Set<String>, until: Date) async {
        let groups = places(ids)
        removeFromList(ids)
        do {
            for (place, ids) in groups {
                guard let snoozed = mailbox(role: "snoozed", in: place) else { continue }
                let folders = folders(in: place)
                try await update(targets(ids, in: place), in: place) { Patch.snooze($0, until: until, snoozedMailbox: snoozed.id, folders: folders) }
            }
        } catch {
            alert = error.localizedDescription
        }
        await refresh(groups.keys)
    }

    func hasLabel(_ label: Mailbox, _ ids: Set<String>) -> Bool {
        let rows = conversations.filter { ids.contains($0.id) }
        return !rows.isEmpty && rows.allSatisfy { $0.email.mailboxIds[label.id] == true }
    }

    func setLabel(_ label: Mailbox, _ on: Bool, for ids: Set<String>) async {
        if !on && label.id == selectedMailbox?.mailbox { removeFromList(ids) }
        let groups = places(ids).filter { labels(in: $0.key).contains(label) }
        do {
            // Labels belong to one account.
            for (place, ids) in groups {
                try await update(targets(ids, in: place), in: place) { _ in Patch.label(label.id, on) }
            }
        } catch {
            alert = error.localizedDescription
        }
        await refresh(groups.keys)
    }

    // MARK: Labels

    /// Make a label, or rename one (from `labelEditor`). Throws so the sheet can say what's wrong.
    func saveLabel(_ edit: LabelEdit, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let login = login(edit.login) else { throw NotConnected() }
        if let label = edit.label {
            try await login.client.renameLabel(label, to: name, account: edit.account)
        } else {
            let id = try await login.client.createLabel(name, account: edit.account)
            // Made from a conversation's Labels menu: those conversations get it straight away.
            if !edit.labelling.isEmpty {
                await refresh(login)
                if let label = labels(in: MailboxRef(login: login.id, account: edit.account, mailbox: "")).first(where: { $0.id == id }) {
                    await setLabel(label, true, for: edit.labelling)
                }
                return
            }
        }
        await refresh(login)
    }

    /// Delete a label after asking (its mail stays in its folders).
    func deleteLabel(_ ref: MailboxRef) async {
        guard let login = login(ref.login) else { return }
        do {
            try await login.client.deleteLabel(ref.mailbox, account: ref.account)
            if selectedMailbox == ref { selectedMailbox = nil }
        } catch {
            alert = error.localizedDescription
        }
        await refresh(login)
    }

    // MARK: Dragging to the sidebar

    /// What a conversation dragged out of the list carries: a marker and the thread ids (the list knows where they are).
    static let dragPrefix = "wren-conversations:"

    func dragPayload(for id: String) -> String {
        let ids = selectedThreads.contains(id) ? selectedThreads : [id]
        return Self.dragPrefix + ids.sorted().joined(separator: ",")
    }

    static func dropped(_ items: [String]) -> Set<String> {
        Set(items.filter { $0.hasPrefix(dragPrefix) }.flatMap { $0.dropFirst(dragPrefix.count).split(separator: ",").map(String.init) })
    }

    /// Whether conversations from the list can be dropped on a sidebar mailbox: one in the same account, other than
    /// the one being shown (moving between accounts would mean copying mail, which Wren doesn't do).
    func canDrop(on ref: MailboxRef) -> Bool {
        guard ref != .allInboxes, ref != selectedMailbox, let target = mailbox(ref) else { return false }
        if ["drafts", "sent", "snoozed"].contains(target.role ?? "") { return false }
        let from = selectedMailbox == .allInboxes ? Set(rowPlaces.values.map { "\($0.login) \($0.account)" }) : Set([selectedMailbox].compactMap { $0.map { "\($0.login) \($0.account)" } })
        return from.contains("\(ref.login) \(ref.account)")
    }

    /// Conversations dropped on a sidebar mailbox: moved to a folder, or given a label.
    func drop(_ ids: Set<String>, on ref: MailboxRef) async {
        let ids = ids.filter { place(of: $0).map { $0.login == ref.login && $0.account == ref.account } ?? false }
        guard !ids.isEmpty, let target = mailbox(ref) else { return }
        if let role = target.role {
            await move(ids, toFolder: role)
        } else {
            await setLabel(target, true, for: ids)
        }
    }

    /// Mark everything in a mailbox as read.
    func markAllRead(in ref: MailboxRef) async {
        let places = ref == .allInboxes ? inboxes : [ref]
        for place in places {
            do {
                try await login(place.login)?.client.markAllRead(account: place.account, mailbox: place.mailbox)
            } catch {
                alert = error.localizedDescription
            }
        }
        await refresh(places)
    }

    /// Delete everything in the Trash or Junk for good (after asking: see confirmingEmpty).
    func empty(_ ref: MailboxRef) async {
        guard let login = login(ref.login), ["trash", "junk"].contains(mailbox(ref)?.role ?? "") else { return }
        do {
            try await login.client.empty(account: ref.account, mailbox: ref.mailbox)
        } catch {
            alert = error.localizedDescription
        }
        // What was moved there can't be put back any more.
        undoManager?.removeAllActions()
        await refresh(login)
    }

    private func updateRows(_ ids: Set<String>, _ change: (inout Email) -> Void) {
        for i in conversations.indices where ids.contains(conversations[i].id) { change(&conversations[i].email) }
    }

    /// Take rows out of the list right away; when the selection goes with them, select the next one, as Mail does.
    private func removeFromList(_ ids: Set<String>) {
        var next: String?
        if !selectedThreads.isEmpty, selectedThreads.isSubset(of: ids), let last = conversations.lastIndex(where: { ids.contains($0.id) }) {
            next = conversations[(last + 1)...].first { !ids.contains($0.id) }?.id ?? conversations[..<last].last { !ids.contains($0.id) }?.id
        }
        withAnimation(Self.motion) { conversations.removeAll { ids.contains($0.id) } }
        total = max(0, total - ids.count)
        selectedThreads.subtract(ids)
        if selectedThreads.isEmpty, let next { selectedThreads = [next] }
    }

    /// A critically damped spring, or none when Reduce Motion is on.
    static var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.3)
    }

    // MARK: Writing

    var replyTarget: Email? { thread.last { !$0.isDraft } }

    /// Reply and Forward go with the selection, as the other actions do, and answer the newest message once it's loaded.
    var canReply: Bool { selectedThreads.count == 1 && currentRole != "drafts" }

    /// A draft in an account, marked with its sign-in.
    private func draft(in place: MailboxRef?, _ make: (_ account: String, _ identities: [Identity]) -> Draft) -> Draft? {
        guard let place, let login = login(place.login) else { return nil }
        var d = make(place.account, login.identities[place.account] ?? [])
        d.login = login.id
        return d
    }

    /// New messages come from the account being looked at, or the first sign-in.
    private var writingPlace: MailboxRef? {
        if let ref = selectedMailbox, ref != .allInboxes { return ref }
        return inboxes.first
    }

    func newDraft(to: String = "") -> Draft? {
        draft(in: writingPlace) { .new(account: $0, identity: $1.first, to: to) }
    }

    func replyDraft(to email: Email? = nil, all: Bool) -> Draft? {
        guard let email = email ?? replyTarget else { return nil }
        return encrypted(email) { email in draft(in: threadPlace) { .reply(to: email, all: all, account: $0, identities: $1) } }
    }

    func forwardDraft(of email: Email? = nil) -> Draft? {
        guard let email = email ?? replyTarget else { return nil }
        return encrypted(email) { email in draft(in: threadPlace) { .forward(email, account: $0, identities: $1) } }
    }

    /// Answering encrypted mail: quoted as it was decrypted (when it was), and encrypted again by default.
    /// shortcut: files inside an encrypted message aren't forwarded; upload them along if people ask.
    private func encrypted(_ email: Email, _ make: (Email) -> Draft?) -> Draft? {
        guard PGPKind(email)?.isEncrypted == true else { return make(email) }
        var d = make(decrypted[email.id].map { $0.shown(in: email) } ?? email)
        d?.encrypt = true
        return d
    }

    /// Lock a sign-in's key and forget what it decrypted.
    func lockPGP(_ login: Login) {
        PGP.shared.lock(login)
        decrypted = [:]
    }

    func editDraft(_ email: Email) -> Draft? {
        draft(in: threadPlace) { .editing(email, account: $0, identities: $1) }
    }

    /// The draft in a conversation in the list, to keep writing it; fetched when the reader hasn't loaded it yet.
    func draftToEdit(inThread id: String) async -> Draft? {
        if let email = thread.last(where: { $0.isDraft && $0.threadId == id }) { return editDraft(email) }
        guard let place = place(of: id), let login = login(place.login),
              let emails = try? await login.client.conversation(account: place.account, threadId: id),
              let email = emails.last(where: \.isDraft)
        else { return nil }
        return draft(in: place) { .editing(email, account: $0, identities: $1) }
    }

    /// The sign-in a draft is written in (drafts saved before there were several belong to the first).
    private func login(of draft: Draft) -> Login? {
        login(draft.login) ?? logins.first
    }

    private func place(of draft: Draft) -> MailboxRef? {
        login(of: draft).map { MailboxRef(login: $0.id, account: draft.accountId, mailbox: "") }
    }

    func identities(for draft: Draft) -> [Identity] {
        login(of: draft)?.identities[draft.accountId] ?? []
    }

    func identity(for draft: Draft) -> Identity? {
        let list = identities(for: draft)
        return list.first { $0.id == draft.identityId } ?? list.first
    }

    /// Save into Drafts (replacing the draft it came from) and return the new draft's id.
    func save(_ draft: Draft) async throws -> String {
        guard let login = login(of: draft), let place = place(of: draft), let identity = identity(for: draft), let drafts = mailbox(role: "drafts", in: place) else { throw NotConnected() }
        let id = try await login.client.save(draft, from: identity, draftsMailbox: drafts.id)
        await refresh(login)
        return id
    }

    /// Send a saved draft, at `date` or now. Sent now from a message window (`undo` is the message as written, to
    /// open again), it's held for a few seconds first (Settings → Composing), so Undo Send can stop it.
    func send(_ draft: Draft, savedAs emailId: String, at date: Date? = nil, undo: Draft? = nil) async throws {
        guard let login = login(of: draft), let place = place(of: draft), let identity = identity(for: draft),
              let drafts = mailbox(role: "drafts", in: place), let sent = mailbox(role: "sent", in: place)
        else { throw NotConnected() }
        let hold = Self.undoSendSeconds
        let held = date == nil && undo != nil && hold > 0 ? Date.now.addingTimeInterval(Double(hold)) : nil
        let submission = try await login.client.submit(
            emailId: emailId, account: draft.accountId, identity: identity, recipients: draft.recipients, sendAt: date ?? held,
            privateLinkDays: draft.privateLinkDays, draftsMailbox: drafts.id, sentMailbox: sent.id
        )
        if let held, let undo, submission.isPending {
            let pending = PendingSend(submission: submission.id, login: login.id, account: draft.accountId, draft: undo, until: submission.sendAt ?? held)
            pendingSend = pending
            undoManager?.registerUndo(withTarget: self) { store in
                Task { await store.undoSend(pending) }
            }
            undoManager?.setActionName("Send")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, pending.until.timeIntervalSinceNow) + 1))
                if self?.pendingSend == pending { self?.pendingSend = nil }
            }
        }
        await refresh(login)
    }

    /// How long a message waits before it goes, so it can be undone (0: straight away).
    static var undoSendSeconds: Int {
        UserDefaults.standard.object(forKey: "undoSendSeconds") as? Int ?? 10
    }

    /// Stop a message held for Undo Send and open it again to keep writing.
    func undoSend(_ pending: PendingSend? = nil) async {
        guard let pending = pending ?? pendingSend, let login = login(pending.login) else { return }
        if pendingSend == pending { pendingSend = nil }
        do {
            let back = try await login.client.cancel(submission: pending.submission, account: pending.account)
            var draft = pending.draft
            draft.replaces = back
            openWindow?(id: "compose", value: draft)
            NSApp.activate()
        } catch JMAPError.notSaved("cannotUnsend", _) {
            alert = "It was too late to undo: the message has been sent."
        } catch {
            alert = "The message couldn’t be stopped: \(error.localizedDescription)"
        }
        await refresh(login)
    }

    // MARK: Scheduled messages

    /// Messages waiting to go out in every sign-in's accounts, soonest first.
    func scheduled() async -> [(submission: Submission, login: String, account: String)] {
        var out: [(submission: Submission, login: String, account: String)] = []
        for login in logins {
            for account in login.accounts where account.canSend != false {
                guard let list = try? await login.client.pendingSubmissions(account: account.id) else { continue }
                out += list.map { ($0, login.id, account.id) }
            }
        }
        return out.sorted { ($0.submission.sendAt ?? .distantFuture) < ($1.submission.sendAt ?? .distantFuture) }
    }

    /// Stop a scheduled message; it goes back to Drafts. With `edit`, it opens to change and send again.
    func cancelScheduled(_ submission: Submission, login loginId: String, account: String, edit: Bool) async throws {
        guard let login = login(loginId) else { throw NotConnected() }
        let back = try await login.client.cancel(submission: submission.id, account: account)
        if edit, let back, let threadId = submission.threadId,
           let email = try await login.client.conversation(account: account, threadId: threadId).first(where: { $0.id == back }) {
            var d = Draft.editing(email, account: account, identities: login.identities[account] ?? [])
            d.login = login.id
            openWindow?(id: "compose", value: d)
        }
        await refresh(login)
    }

    /// Whether a draft's account has Wren's extension (private links, PGP keys).
    func hasWren(_ draft: Draft) -> Bool {
        login(of: draft)?.accounts.first { $0.id == draft.accountId }?.hasWren == true
    }

    // MARK: Invitations

    /// Whether the conversation being read is in an account that can send (not a shared mailbox you can only read).
    /// Wren's session says; with an older server it's learned when an answer is refused.
    var canSendHere: Bool {
        guard let place = threadPlace else { return false }
        if readOnly.contains("\(place.login) \(place.account)") { return false }
        return login(place.login)?.accounts.first { $0.id == place.account }?.canSend ?? true
    }

    // MARK: Mailing lists

    /// Unsubscribe from the list a message came from; Wren asks the list, or writes to it. When the list only has
    /// a page for it, that's what comes back to open.
    func unsubscribe(_ email: Email) async throws -> Unsubscribed {
        guard let place = threadPlace, let login = login(place.login) else { throw NotConnected() }
        let done = try await login.client.unsubscribe(from: email.id, account: place.account)
        let sender = email.from?.first?.email.lowercased()
        for i in thread.indices where thread[i].from?.first?.email.lowercased() == sender { thread[i].unsubscribed = true }
        return done
    }

    /// Accept, maybe or decline the invitation in an email; the organizer gets the answer from Wren.
    /// Returns who the answer went to.
    func answer(_ email: Email, _ answer: Invite.Answer, comment: String) async throws -> String? {
        guard let place = threadPlace, let login = login(place.login) else { throw NotConnected() }
        let to: String?
        do {
            to = try await login.client.answer(invite: email.id, answer, comment: comment, account: place.account)
        } catch JMAPError.method("forbidden", let detail) {
            readOnly.insert("\(place.login) \(place.account)")
            throw JMAPError.method("forbidden", detail)
        }
        await refresh(login)
        return to
    }

    /// Throw away a draft that was saved before.
    func discard(_ draft: Draft) async {
        guard let id = draft.replaces, let login = login(of: draft) else { return }
        do {
            try await login.client.destroy(account: draft.accountId, ids: [id])
        } catch {
            alert = error.localizedDescription
        }
        await refresh(login)
    }

    func upload(_ url: URL, for draft: Draft) async throws -> Draft.File {
        guard let login = login(of: draft) else { throw NotConnected() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let blob = try await login.client.upload(data, type: type, account: draft.accountId)
        return Draft.File(blobId: blob.blobId, name: url.lastPathComponent, type: blob.type, size: blob.size)
    }

    /// A message from a mailto: link (another app, or a link in a message), once Wren is ready to write one.
    func openMailto(_ link: URL) {
        pendingLinks.append(link)
        openPending()
    }

    /// Files opened with Wren (dropped on its Dock icon, or from the Share menu): a new message with them attached.
    func openFiles(_ files: [URL]) {
        pendingLinks += files
        openPending()
    }

    private func openPending() {
        guard let openWindow, !pendingLinks.isEmpty, let login = logins.first, let personal = login.personal, let identities = login.identities[personal.id] else { return }
        for link in pendingLinks where !link.isFileURL {
            var d = Draft.mailto(link, account: personal.id, identity: identities.first)
            d.login = login.id
            openWindow(id: "compose", value: d)
        }
        let files = pendingLinks.filter(\.isFileURL)
        pendingLinks = []
        NSApp.activate()
        guard !files.isEmpty else { return }
        var message = Draft.new(account: personal.id, identity: identities.first)
        message.login = login.id
        let draft = message
        Task {
            // shortcut: the files upload before the window opens, so big ones take a while with nothing shown; hand them
            // to the compose window to upload with progress if that's a bother.
            var withFiles = draft
            for file in files {
                do {
                    let attached = try await upload(file, for: withFiles)
                    withFiles.files.append(attached)
                } catch {
                    alert = "\(file.lastPathComponent) couldn’t be attached: \(error.localizedDescription)"
                }
            }
            openWindow(id: "compose", value: withFiles)
        }
    }

    /// Addresses for what's being typed in a To, Cc or Bcc field: contacts on the draft's server first,
    /// then people in the mail already loaded.
    func suggestions(for text: String, in draft: Draft) async -> [EmailAddress] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return [] }
        var found: [EmailAddress] = []
        if let login = login(of: draft), let personal = login.personal, personal.capabilities.contains(Capability.contacts) {
            found = (try? await login.client.contacts(matching: text, account: personal.id)) ?? []
        }
        let seen = (conversations.map(\.email) + thread).flatMap { ($0.from ?? []) + ($0.to ?? []) + ($0.cc ?? []) }
        found += seen.filter { $0.email.localizedCaseInsensitiveContains(text) || ($0.name ?? "").localizedCaseInsensitiveContains(text) }
        var emails = Set<String>()
        return Array(found.filter { emails.insert($0.email.lowercased()).inserted }.prefix(8))
    }

    // MARK: Out of office

    /// A sign-in's out-of-office reply, if its server offers one.
    func vacation(_ login: Login) async throws -> VacationResponse? {
        guard let personal = login.personal, personal.capabilities.contains(Capability.vacation) else { return nil }
        return try await login.client.vacation(account: personal.id)
    }

    func saveVacation(_ reply: VacationResponse, was old: VacationResponse, in login: Login) async throws {
        guard let personal = login.personal else { throw NotConnected() }
        try await login.client.setVacation(reply, was: old, account: personal.id)
    }

    // MARK: Attachments

    /// The open conversation's sign-in and account, where its files come from.
    var fileSource: (client: JMAPClient, account: String)? {
        guard let place = threadPlace, let login = login(place.login) else { return nil }
        return (login.client, place.account)
    }

    func download(_ part: BodyPart) async throws -> Data {
        guard let source = fileSource else { throw NotConnected() }
        return try await source.client.download(part, account: source.account)
    }

    nonisolated private static func fileName(_ part: BodyPart) -> String {
        let name = (part.name ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Attachment" : name
    }

    /// A copy in a temporary folder, to open, preview or drag out. Files the app writes are quarantined
    /// (LSFileQuarantineEnabled), so Gatekeeper checks them before they open.
    nonisolated static func temporaryFile(_ part: BodyPart, account: String, client: JMAPClient) async throws -> URL {
        try temporaryFile(fileName(part), try await client.download(part, account: account))
    }

    nonisolated static func temporaryFile(_ name: String, _ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Wren").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(BodyPart(size: data.count, name: name, type: "")))
        try data.write(to: url)
        return url
    }

    func temporaryFile(_ part: BodyPart) async throws -> URL {
        guard let source = fileSource else { throw NotConnected() }
        return try await Self.temporaryFile(part, account: source.account, client: source.client)
    }

    /// Open with its app.
    func openAttachment(_ part: BodyPart) async {
        do {
            NSWorkspace.shared.open(try await temporaryFile(part))
        } catch {
            alert = error.localizedDescription
        }
    }

    func saveAttachment(_ part: BodyPart) async {
        do {
            saveToDownloads(Self.fileName(part), try await download(part))
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Into Downloads (numbered if the name is taken), shown in the Finder.
    func saveToDownloads(_ fileName: String, _ data: Data) {
        do {
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let name = Self.fileName(BodyPart(size: data.count, name: fileName, type: "")) as NSString
            var url = downloads.appendingPathComponent(name as String)
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                let numbered = name.pathExtension.isEmpty ? "\(name) \(n)" : "\(name.deletingPathExtension) \(n).\(name.pathExtension)"
                url = downloads.appendingPathComponent(numbered)
                n += 1
            }
            try data.write(to: url, options: .withoutOverwriting)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: Dock and notifications

    var unreadInInboxes: Int { inboxes.compactMap { mailbox($0) }.map(\.unreadEmails).reduce(0, +) }

    /// Unread mail in every sign-in's Inbox: on the Dock icon, and in the widget when there's an App Group for it.
    private func updateDockBadge() {
        let unread = unreadInInboxes
        NSApp.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
        let mail = UnreadMail(inboxes: inboxes.compactMap { ref in
            guard let login = login(ref.login), let account = login.accounts.first(where: { $0.id == ref.account }) else { return nil }
            return .init(name: account.isPersonal ? login.username : account.name, unread: mailbox(ref)?.unreadEmails ?? 0)
        })
        guard mail != widgetMail, UnreadMail.defaults != nil else { return }
        widgetMail = mail
        mail.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The buttons on a new-mail notification.
    nonisolated static var newMail: UNNotificationCategory {
        UNNotificationCategory(identifier: "newMail", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Reply"),
            UNNotificationAction(identifier: "archive", title: "Archive", options: []),
            UNNotificationAction(identifier: "read", title: "Mark as Read", options: []),
        ], intentIdentifiers: [])
    }

    /// What a new-mail notification was clicked for: a button, done without bringing Wren forward, or the
    /// notification itself, which opens the conversation.
    func notificationAction(_ action: String, thread: String, in place: MailboxRef, reply text: String?) async {
        switch action {
        case "archive": await archive([thread], in: place)
        case "read": await setRead([thread], true, in: place)
        case "reply": await quickReply(text ?? "", to: thread, in: place)
        case UNNotificationDefaultActionIdentifier: show(thread, in: place)
        default: break
        }
    }

    private func quickReply(_ text: String, to threadId: String, in place: MailboxRef) async {
        guard let emails = try? await login(place.login)?.client.conversation(account: place.account, threadId: threadId),
              let email = emails.last(where: { !$0.isDraft }),
              var reply = draft(in: place, { .reply(to: email, all: false, account: $0, identities: $1) })
        else {
            alert = "Wren couldn’t reach the server to send your reply: “\(text)”"
            return
        }
        reply.body = text + reply.body
        do {
            let saved = try await save(reply)
            reply.replaces = saved
            try await send(reply, savedAs: saved)
            await setRead([threadId], true, in: place)
        } catch {
            // Nothing typed is lost: the reply opens to send again.
            alert = "Your reply wasn’t sent: \(error.localizedDescription)"
            openWindow?(id: "compose", value: reply)
            NSApp.activate()
        }
    }

    /// A notification for each new unread message in a sign-in's Inbox.
    private func notifyNewMail(_ login: Login) async {
        guard let personal = login.personal, let inbox = login.ref(role: "inbox", in: personal.id),
              let page = try? await login.client.conversations(account: inbox.account, mailbox: inbox.mailbox, limit: 20)
        else { return }
        let unread = page.list.map(\.email).filter(\.isUnread)
        // Notifications about mail that's been read or filed since, here or anywhere else, go away.
        // shortcut: only the newest 20 conversations are looked at, so with more unread than that the oldest
        // notifications go too.
        let center = UNUserNotificationCenter.current()
        let current = Set(unread.map(\.id))
        let stale = await center.deliveredNotifications()
            .filter { $0.request.content.userInfo["login"] as? String == login.id && !current.contains($0.request.identifier) }
            .map(\.request.identifier)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        let known = login.announced
        login.announced = (known ?? []).union(unread.map(\.id))
        guard let known else { return }
        for email in unread where !known.contains(email.id) {
            let content = UNMutableNotificationContent()
            content.title = email.from?.first?.displayName ?? "New Message"
            content.subtitle = logins.count > 1 ? "\(login.username) · \(email.subject ?? "")" : email.subject ?? ""
            content.body = email.preview ?? ""
            content.sound = .default
            content.categoryIdentifier = Self.newMail.identifier
            content.threadIdentifier = email.threadId
            // Clicking it opens the conversation; its buttons are in notificationAction (both from AppDelegate).
            content.userInfo = ["login": login.id, "account": inbox.account, "mailbox": inbox.mailbox, "thread": email.threadId]
            try? await center.add(UNNotificationRequest(identifier: email.id, content: content, trigger: nil))
        }
    }
}
