import AppKit
import SwiftUI
import UserNotifications
import WrenKit

@main
struct WrenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MailStore.shared

    var body: some Scene {
        Window("Wren", id: "main") {
            RootView()
                .environment(store)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { MailCommands(store: store) }
        // Links and files are the app delegate's: SwiftUI would otherwise rebuild this window for each one.
        .handlesExternalEvents(matching: [])

        WindowGroup("New Message", id: "compose", for: Draft.self) { $draft in
            ComposeView(value: $draft)
                .environment(store)
        }
        .defaultSize(width: 640, height: 560)
        // mailto: links go to the app delegate, which fills in the message; never a blank window from here.
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch ends, so the click on a notification that launched Wren arrives here.
        if MailStore.canNotify { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare `swift run` binary starts as a background process; make it a regular app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// mailto: links from other apps (Wren is registered for them in Info.plist).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailto" { MailStore.shared.openMailto(url) }
    }

    /// Clicking a new-mail notification opens that conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let login = info["login"] as? String, let account = info["account"] as? String, let mailbox = info["mailbox"] as? String, let thread = info["thread"] as? String {
            Task { @MainActor in MailStore.shared.show(thread, in: MailboxRef(login: login, account: account, mailbox: mailbox)) }
        }
        completionHandler()
    }
}

struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch store.phase {
            case .starting: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut: SignInView()
            case .signedIn: MainView()
            }
        }
        .onAppear {
            store.openWindow = openWindow
            store.restore()
        }
        // And if one comes here anyway, this window takes it as it is (without these SwiftUI rebuilt it for each
        // mailto: link, losing its size and selection).
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        #if DEBUG
        .modifier(Demo())
        #endif
    }
}

struct MailCommands: Commands {
    let store: MailStore
    @Environment(\.openWindow) private var openWindow

    private var selection: Set<String> { store.selectedThreads }
    private var signedIn: Bool { store.phase == .signedIn }

    private func act(_ action: @escaping (MailStore, Set<String>) async -> Void) {
        let ids = selection
        Task { await action(store, ids) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { if let d = store.newDraft() { openWindow(id: "compose", value: d) } }
                .keyboardShortcut("n")
                .disabled(!signedIn)
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") { Task { await store.refresh() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!signedIn)
        }
        CommandMenu("Message") {
            Button("Reply") { if let d = store.replyDraft(all: false) { openWindow(id: "compose", value: d) } }
                .keyboardShortcut("r")
                .disabled(!store.canReply)
            Button("Reply All") { if let d = store.replyDraft(all: true) { openWindow(id: "compose", value: d) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!store.canReply)
            Button("Forward") { if let d = store.forwardDraft() { openWindow(id: "compose", value: d) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!store.canReply)
            Divider()
            Button("Archive") { act { await $0.archive($1) } }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(selection.isEmpty || ["archive", "drafts", "sent"].contains(store.currentRole ?? ""))
            Button(store.currentRole == "trash" ? "Delete Forever…" : "Move to Trash") { act { await $0.trash($1) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selection.isEmpty)
            Button(store.currentRole == "junk" ? "Not Junk" : "Move to Junk") { act { await $0.junk($1) } }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(selection.isEmpty || ["drafts", "sent"].contains(store.currentRole ?? ""))
            Divider()
            Button("Mark as Read") { act { await $0.setRead($1, true) } }
                .disabled(selection.isEmpty)
            Button("Mark as Unread") { act { await $0.setRead($1, false) } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(selection.isEmpty)
            Button("Flag") { act { await $0.toggleFlag($1) } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(selection.isEmpty)
            Menu("Snooze") {
                ForEach(SnoozeTime.choices(), id: \.title) { choice in
                    Button(choice.title) { act { await $0.snooze($1, until: choice.date) } }
                }
            }
            .disabled(selection.isEmpty || !store.canSnooze)
        }
    }
}
