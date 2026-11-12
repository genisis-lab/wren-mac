#if DEBUG
import AppKit
import SwiftUI
import WrenKit

/// The screenshot run (.github/workflows/screenshots.yml), in debug builds only and only when WREN_DEMO_OUT is set:
/// signs in to a test server, walks through the app's screens and saves each window as a PNG.
struct Demo: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    private let env = ProcessInfo.processInfo.environment
    private var store: MailStore { .shared }
    @MainActor private static var started = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !Self.started, let out = env["WREN_DEMO_OUT"] else { return }
                Self.started = true
                // Not .task, which SwiftUI cancels whenever it rebuilds the view: every wait after that returns at once.
                Task { @MainActor in await run(URL(fileURLWithPath: out)) }
            }
            .onDisappear { if Self.started { log("the main window's view went away") } }
    }

    /// Straight to the log, unbuffered, so the workflow sees how far the walk got even if the app stops.
    private func log(_ line: String) { FileHandle.standardOutput.write(Data("demo: \(line)\n".utf8)) }

    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 150 {
            await wait(0.2)
            tries += 1
        }
    }

    /// Ask the workflow for pictures of each window and the whole screen, and wait for them. The workflow takes
    /// them because it has the Screen Recording permission; an app opened through Launch Services doesn't.
    private func shoot(_ name: String, in dir: URL) async {
        let base = dir.appending(path: "\(env["WREN_DEMO_TAG"] ?? "light")-\(name)")
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
        let request = windows.map { "\($0.windowNumber)\n" }.joined()
        let temporary = dir.appending(path: ".\(name).tmp")
        try? request.write(to: temporary, atomically: true, encoding: .utf8)
        try? FileManager.default.moveItem(at: temporary, to: base.appendingPathExtension("request"))
        let done = base.appendingPathExtension("done")
        var tries = 0
        while !FileManager.default.fileExists(atPath: done.path), tries < 100 {
            await wait(0.2)
            tries += 1
        }
        try? FileManager.default.removeItem(at: done)
        log("\(name): \(windows.map(\.title))")
    }

    private func select(_ match: (Conversation) -> Bool) async {
        guard let c = store.conversations.first(where: match) else { return log("no such conversation") }
        store.selectedThreads = [c.id]
        await until { store.thread.first?.threadId == c.id }
        await wait(2.5)
    }

    private func run(_ dir: URL) async {
        if env["WREN_DEMO_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.windows.first?.setFrame(NSRect(x: 40, y: 80, width: 1200, height: 760), display: true)
        await until { store.phase != .starting }
        await wait(1.5)
        await shoot("01-signin", in: dir)

        guard let server = env["WREN_DEMO_SERVER"].flatMap(URL.init(string:)), let user = env["WREN_DEMO_USER"], let password = env["WREN_DEMO_PASSWORD"]
        else { exit(1) }
        store.add(JMAPClient(server: server, username: user, password: password))
        if env["WREN_DEMO_OFFLINE"] == "1" { return await offline(dir, server: server) }
        await until { !store.conversations.isEmpty && store.logins.first?.quota != nil }
        await wait(1.5)
        await shoot("02-inbox", in: dir)

        await select { $0.count > 1 }
        await shoot("03-thread", in: dir)
        await select { $0.email.subject?.contains("variable") == true }
        await shoot("04-html-trackers", in: dir)
        await select { $0.email.subject?.contains("Quarterly") == true }
        await shoot("05-attachment", in: dir)

        store.search = "lunch"
        await until { store.conversations.contains { $0.snippet != nil } }
        await wait(1.5)
        await shoot("06-search", in: dir)
        store.search = ""

        // What a notification click does: from another mailbox, straight to the conversation in the Inbox.
        if let inbox = store.inboxes.first, let archive = store.login(inbox.login)?.ref(role: "archive", in: inbox.account),
           let lunch = store.conversations.first(where: { $0.count > 1 }) {
            store.selectedMailbox = archive
            await wait(2)
            store.show(lunch.id, in: inbox)
            await until { store.thread.first?.threadId == lunch.id }
            await wait(2)
            await shoot("07-notification-click", in: dir)
        }

        // Typing in To: suggestions from contacts and from mail.
        if let draft = store.newDraft() { store.openWindow?(id: "compose", value: draft) }
        await wait(2.5)
        if let compose = NSApp.windows.first(where: { $0.isVisible && $0.title == "New Message" }) {
            compose.makeKeyAndOrderFront(nil)
            // The To field has focus when the window opens; type into it as the keyboard would.
            (compose.firstResponder as? NSTextView)?.insertText("gr", replacementRange: NSRange(location: NSNotFound, length: 0))
            await wait(2)
            await shoot("08-compose-suggestions", in: dir)
            compose.close()
        }

        // A mailto: link from another app, through Launch Services like a real one.
        if let link = URL(string: "mailto:grace@example.com?subject=Hello%20from%20a%20link&body=Hi%20Grace%2C") {
            _ = try? await NSWorkspace.shared.open([link], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        await wait(3)
        await shoot("09-mailto", in: dir)
        NSApp.windows.filter { $0.title.contains("Hello from a link") }.forEach { $0.close() }

        // A file opened with Wren, as the Share extension (and dropping on the Dock icon) does: a message with it attached.
        let file = FileManager.default.temporaryDirectory.appending(path: "Notes for Grace.txt")
        try? "Lunch is at 12:30.".write(to: file, atomically: true, encoding: .utf8)
        _ = try? await NSWorkspace.shared.open([file], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        await until { NSApp.windows.contains { $0.isVisible && $0.title == "New Message" } }
        await wait(2)
        await shoot("14-file-opened", in: dir)
        NSApp.windows.filter { $0.title == "New Message" }.forEach { $0.close() }

        // A reply typed into a new-mail notification, then the conversation found in Spotlight from another mailbox.
        if let inbox = store.inboxes.first, let archive = store.login(inbox.login)?.ref(role: "archive", in: inbox.account),
           let lunch = store.conversations.first(where: { $0.email.subject?.contains("Lunch") == true }) {
            await store.notificationAction("reply", thread: lunch.id, in: inbox, reply: "Sounds good, see you there.")
            store.selectedMailbox = archive
            await wait(2)
            await store.showFound(Spotlight.id(lunch.id, in: inbox))
            await until { store.thread.first?.threadId == lunch.id && store.thread.count > lunch.count }
            await wait(2)
            await shoot("15-notification-reply", in: dir)
        }

        // The Open Mailbox shortcut.
        _ = try? await OpenMailboxIntent(mailbox: .sent).perform()
        await until { store.mailbox(store.selectedMailbox)?.role == "sent" && !store.conversations.isEmpty }
        await wait(2)
        await shoot("16-shortcut-sent", in: dir)
        log("unread in the Inboxes: \(store.unreadInInboxes)")
        await newFeatures(dir)
        await richMail(dir)

        // A second sign-in: All Inboxes, and its own mailboxes in the sidebar.
        if let user2 = env["WREN_DEMO_USER2"], let password2 = env["WREN_DEMO_PASSWORD2"] {
            store.add(JMAPClient(server: server, username: user2, password: password2))
            await until { store.selectedMailbox == .allInboxes && store.conversations.count > 7 }
            await wait(2)
            await select { $0.email.subject?.contains("FORTRAN") == true }
            await shoot("10-all-inboxes", in: dir)
        }

        for tab in ["general", "account", "signatures", "vacation", "viewing", "encryption"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            openSettings()
            await wait(2)
            await shoot("11-settings-\(tab)", in: dir)
        }
        exit(0)
    }

    /// Sent back to the Inbox (where AppKit used to log a reentrant table operation), a conversation in its own
    /// window with Find, a search of all mailboxes, Scheduled Messages and the label sheet.
    private func newFeatures(_ dir: URL) async {
        guard let inbox = store.inboxes.first else { return }
        store.selectedMailbox = inbox
        await until { store.currentRole == "inbox" && !store.conversations.isEmpty }
        await wait(2)
        if let lunch = store.conversations.first(where: { $0.count > 1 }) {
            store.openInWindow(lunch.id)
            await until { NSApp.windows.contains { $0.isVisible && $0.title.contains("Lunch") } }
            await wait(2.5)
            await shoot("17-conversation-window", in: dir)
            NSApp.windows.filter { $0.isVisible && $0.title.contains("Lunch") && $0.title != "Wren" }.forEach { $0.close() }
        }
        store.searchScope = .everywhere
        store.search = "lunch"
        await until { store.searchingEverywhere && !store.conversations.isEmpty && !store.isLoading }
        await wait(1.5)
        await shoot("18-search-all-mailboxes", in: dir)
        store.search = ""
        store.searchScope = .mailbox
        await wait(1)
        store.showingScheduled = true
        await wait(2)
        await shoot("19-scheduled", in: dir)
        store.showingScheduled = false
        await wait(1)
        store.labelEditor = LabelEdit(login: inbox.login, account: inbox.account, name: "Travel")
        await wait(1.5)
        await shoot("20-new-label", in: dir)
        store.labelEditor = nil
        await wait(1)
        log("queued changes: \(store.queued.count)")
    }

    private func window(titled title: String) async -> NSWindow? {
        await until { NSApp.windows.contains { $0.isVisible && $0.title == title } }
        return NSApp.windows.first { $0.isVisible && $0.title == title }
    }

    /// Mac 4: a formatted reply sent as a private link, an invitation answered, and PGP mail read and written.
    private func richMail(_ dir: URL) async {
        guard let inbox = store.inboxes.first, let login = store.login(inbox.login) else { return log("no inbox") }
        store.selectedMailbox = inbox
        await until { store.conversations.contains { $0.email.subject == "Cipher settings" } }

        await select { $0.email.subject?.contains("Analytical") == true }
        if var reply = store.replyDraft(all: false) {
            reply.setHTML("<div>Thank you, Ada. I read <b>Note G</b> twice; two things:</div><ol><li>The table in <i>section 4</i> needs one more column.</li>"
                + "<li>Could we <u>meet on Thursday</u>?</li></ol><div><a href=\"https://wren.test/notes\">My notes</a></div>" + (reply.html ?? ""))
            reply.privateLinkDays = 7
            store.openWindow?(id: "compose", value: reply)
            let compose = await window(titled: reply.subject)
            await wait(2.5)
            await shoot("17-rich-reply", in: dir)
            compose?.close()
        }

        await select { $0.email.subject == "Invitation: Planning review" }
        await shoot("18-invite", in: dir)
        // The first pass answers it; a second pass on the same server finds it answered, above the reply.
        if let email = store.thread.last(where: { $0.invite != nil }), email.invite?.rsvp == nil {
            do {
                let to = try await store.answer(email, .accepted, comment: "See you there.")
                log("invite answered, sent to \(to ?? "nobody")")
            } catch {
                log("invite answer failed: \(error.localizedDescription)")
            }
            await until { store.thread.first { $0.id == email.id }?.invite?.rsvp != nil }
            await wait(1.5)
            await shoot("19-invite-answered", in: dir)
        } else if let rsvp = store.thread.last(where: { $0.invite != nil })?.invite?.rsvp {
            log("invitation already answered: \(rsvp)")
        } else {
            log("no invitation on the message (a server without Wren's extension?)")
        }

        // The key backed up on the web, restored with its passphrase (the prompt is skipped here).
        do {
            let key = try await PGP.shared.restore(login, passphrase: "wren demo passphrase")
            log("PGP key restored: \(key.groupedFingerprint) \(key.userIds)")
        } catch {
            return log("PGP restore failed: \(error.localizedDescription)")
        }
        let pgpMail: [(String, PGPKind)] = [("Cipher settings", .encrypted), ("Launch window", .encryptedMIME), ("Status page updated", .signedMIME)]
        for (subject, kind) in pgpMail {
            await select { $0.email.subject == subject }
            if let email = store.thread.last {
                let started = Date.now
                do {
                    let opened = try await store.openPGP(email, kind)
                    log("\(subject): \(kind), \(opened.text?.count ?? 0) characters, signature \(opened.signature?.rawValue ?? "none"), \(Int(Date.now.timeIntervalSince(started) * 1000)) ms")
                } catch {
                    log("\(subject): \(error.localizedDescription)")
                }
            }
            await wait(1)
            await shoot("20-pgp-\(subject.prefix(6).lowercased().replacingOccurrences(of: " ", with: "-"))", in: dir)
        }

        // An encrypted, signed reply: Encrypt is on because the message was encrypted, and it quotes the decrypted text.
        await select { $0.email.subject == "Cipher settings" }
        if var reply = store.replyDraft(all: false) {
            reply.sign = true
            reply.setHTML("<div>Got them, thank you. Thursday it is.</div>" + (reply.html ?? ""))
            store.openWindow?(id: "compose", value: reply)
            let compose = await window(titled: reply.subject)
            await wait(3)
            await shoot("21-encrypted-reply", in: dir)
            compose?.close()
            do {
                guard let sealed = try await store.sealed(reply, forSending: true) else { return log("sealing was cancelled") }
                let id = try await store.save(sealed)
                try await store.send(sealed, savedAs: id)
                log("encrypted reply sent: \(PGPKind.isMessage(sealed.body)), quote kept: \(reply.body.contains("Rotor order"))")
            } catch {
                log("encrypted reply failed: \(error.localizedDescription)")
            }
        }
    }

    /// With the server gone: the sidebar, list and an opened conversation from what's kept on this Mac.
    private func offline(_ dir: URL, server: URL) async {
        if let user2 = env["WREN_DEMO_USER2"], let password2 = env["WREN_DEMO_PASSWORD2"] {
            store.add(JMAPClient(server: server, username: user2, password: password2))
        }
        await until { !store.conversations.isEmpty }
        await wait(3)
        await shoot("12-offline-list", in: dir)
        await select { $0.count > 1 }
        await shoot("13-offline-thread", in: dir)
        exit(0)
    }
}
#endif
