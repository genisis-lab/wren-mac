#if DEBUG
import AppKit
import SwiftUI
import WrenKit

/// The screenshot run (.github/workflows/screenshots.yml), in debug builds only and only when WREN_DEMO_OUT is set:
/// signs in to a test server, walks through the app's screens and saves each window as a PNG.
struct Demo: ViewModifier {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let env = ProcessInfo.processInfo.environment

    func body(content: Content) -> some View {
        content.task {
            guard let out = env["WREN_DEMO_OUT"] else { return }
            await run(URL(fileURLWithPath: out))
        }
    }

    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 150 {
            await wait(0.2)
            tries += 1
        }
    }

    /// Each window on its own (`screencapture -l`), and the whole screen for menus and panels.
    private func shoot(_ name: String, in dir: URL) {
        let tag = env["WREN_DEMO_TAG"] ?? "light"
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
        for (i, window) in windows.enumerated() {
            capture(["-x", "-o", "-l", String(window.windowNumber), dir.appending(path: "\(tag)-\(name)-\(i).png").path])
        }
        capture(["-x", dir.appending(path: "\(tag)-\(name)-screen.png").path])
        print("demo: \(name): \(windows.map(\.title))")
    }

    private func capture(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = arguments
        try? p.run()
        p.waitUntilExit()
    }

    private func select(_ match: (Conversation) -> Bool) async {
        guard let c = store.conversations.first(where: match) else { return print("demo: no such conversation") }
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
        shoot("01-signin", in: dir)

        guard let server = env["WREN_DEMO_SERVER"].flatMap(URL.init(string:)), let user = env["WREN_DEMO_USER"], let password = env["WREN_DEMO_PASSWORD"]
        else { exit(1) }
        store.begin(JMAPClient(server: server, username: user, password: password))
        await until { !store.conversations.isEmpty && store.quota != nil }
        await wait(1.5)
        shoot("02-inbox", in: dir)

        await select { $0.count > 1 }
        shoot("03-thread", in: dir)
        await select { $0.email.subject?.contains("variable") == true }
        shoot("04-html-trackers", in: dir)
        await select { $0.email.subject?.contains("Quarterly") == true }
        shoot("05-attachment", in: dir)

        store.search = "lunch"
        await until { store.conversations.contains { $0.snippet != nil } }
        await wait(1.5)
        shoot("06-search", in: dir)
        store.search = ""

        // What a notification click does: from another mailbox, straight to the conversation in the Inbox.
        let account = store.personalAccount?.id ?? ""
        if let inbox = store.mailbox(role: "inbox", in: account), let archive = store.mailbox(role: "archive", in: account),
           let lunch = store.conversations.first(where: { $0.count > 1 }) {
            store.selectedMailbox = MailboxRef(account: account, mailbox: archive.id)
            await wait(2)
            store.show(lunch.id, in: MailboxRef(account: account, mailbox: inbox.id))
            await until { store.thread.first?.threadId == lunch.id }
            await wait(2)
            shoot("07-notification-click", in: dir)
        }

        // Typing in To: suggestions from contacts and from mail.
        if let draft = store.newDraft() { openWindow(id: "compose", value: draft) }
        await wait(2.5)
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertText("gr", replacementRange: NSRange(location: NSNotFound, length: 0))
        await wait(2)
        shoot("08-compose-suggestions", in: dir)
        NSApp.keyWindow?.close()

        // A mailto: link from another app, through Launch Services like a real one.
        if let link = URL(string: "mailto:grace@example.com?subject=Hello%20from%20a%20link&body=Hi%20Grace%2C") {
            _ = try? await NSWorkspace.shared.open([link], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        await wait(3)
        shoot("09-mailto", in: dir)
        NSApp.windows.filter { $0.title.contains("Hello from a link") }.forEach { $0.close() }

        for tab in ["general", "account", "vacation", "viewing"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            openSettings()
            await wait(2)
            shoot("10-settings-\(tab)", in: dir)
        }
        exit(0)
    }
}
#endif
