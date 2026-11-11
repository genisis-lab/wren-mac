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

        // A second sign-in: All Inboxes, and its own mailboxes in the sidebar.
        if let user2 = env["WREN_DEMO_USER2"], let password2 = env["WREN_DEMO_PASSWORD2"] {
            store.add(JMAPClient(server: server, username: user2, password: password2))
            await until { store.selectedMailbox == .allInboxes && store.conversations.count > 7 }
            await wait(2)
            await select { $0.email.subject?.contains("FORTRAN") == true }
            await shoot("10-all-inboxes", in: dir)
        }

        for tab in ["general", "account", "vacation", "viewing"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            openSettings()
            await wait(2)
            await shoot("11-settings-\(tab)", in: dir)
        }
        exit(0)
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
