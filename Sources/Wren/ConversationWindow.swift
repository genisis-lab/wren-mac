import AppKit
import SwiftUI
import WebKit
import WrenKit

/// A conversation in a window of its own (double-click it in the list, or Message → Open in New Window), as in Mail.
/// It stays up to date while it's open, and its messages fold as they do in the reader.
struct ConversationWindow: View {
    @Binding var value: OpenConversation?
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var thread: [Email] = []
    @State private var problem: String?

    private var place: MailboxRef? { value?.place }
    private var role: String? { store.mailbox(place)?.role }

    var body: some View {
        ConversationMessages(thread: thread)
            .environment(\.conversationPlace, place)
            .overlay {
                if thread.isEmpty, let problem {
                    ContentUnavailableView("Can’t Show This Conversation", systemImage: "exclamationmark.triangle", description: Text(problem))
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .navigationTitle(thread.first?.subject ?? "Conversation")
            .focusedSceneValue(\.printable, thread.isEmpty ? nil : Printable(emails: thread))
            .toolbar {
                ToolbarItemGroup {
                    Button { act { await store.archive($0, in: $1) } } label: { Label("Archive", systemImage: "archivebox") }
                        .help("Archive")
                        .disabled(["archive", "drafts", "sent"].contains(role ?? ""))
                    Button { act { await store.trash($0, in: $1) } } label: { Label("Trash", systemImage: "trash") }
                        .help("Move to Trash")
                        .disabled(role == "trash")
                }
                ToolbarItemGroup {
                    Button { compose(store.replyDraft(to: newest, all: false, in: place)) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        .help("Reply")
                    Button { compose(store.replyDraft(to: newest, all: true, in: place)) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                        .help("Reply All")
                    Button { compose(store.forwardDraft(of: newest, in: place)) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                        .help("Forward")
                }
                ToolbarItem {
                    Button { Printer.print(thread, decrypted: store.decrypted) } label: { Label("Print", systemImage: "printer") }
                        .help("Print (⌘P)")
                        .disabled(thread.isEmpty)
                }
            }
            // Loads again whenever the main window does (an action, or the server saying something changed).
            .task(id: store.reloads) { await load() }
            .frame(minWidth: 480, minHeight: 360)
    }

    private var newest: Email? { thread.last { !$0.isDraft } }

    private func compose(_ draft: Draft?) {
        if let draft { openWindow(id: "compose", value: draft) }
    }

    /// Archive or Trash this conversation, then close the window.
    private func act(_ action: @escaping (Set<String>, MailboxRef) async -> Void) {
        guard let value else { return }
        dismiss()
        Task { await action([value.threadId], value.place) }
    }

    private func load() async {
        guard let value else { return }
        do {
            let emails = try await store.messages(value)
            // Moved or deleted elsewhere: nothing left here.
            if emails.isEmpty, !thread.isEmpty { return dismiss() }
            thread = emails
            problem = emails.isEmpty ? "It may have been moved or deleted." : nil
        } catch {
            if thread.isEmpty { problem = error.localizedDescription }
        }
    }
}

/// The conversation that ⌘P prints: the one in the focused window.
struct Printable: Equatable {
    var emails: [Email]
}

extension FocusedValues {
    @Entry var printable: Printable?
}

/// Prints a conversation: its messages one after another with who, when and to whom, in the same locked-down page as
/// the reader (no scripts, nothing from the web), with tracking pictures taken out and encrypted mail as decrypted.
@MainActor
enum Printer {
    /// The pages being printed, kept until printing is done.
    private static var jobs: [Job] = []

    static func print(_ emails: [Email], decrypted: [String: PGP.Opened]) {
        guard !emails.isEmpty else { return }
        let job = Job(html: html(emails, decrypted: decrypted), title: emails.first?.subject ?? "Message")
        jobs.append(job)
        job.start { done in jobs.removeAll { $0 === done } }
    }

    static func html(_ emails: [Email], decrypted: [String: PGP.Opened]) -> String {
        let subject = emails.first?.subject ?? ""
        var out = "<h2 style=\"margin:0 0 12px\">\(Draft.html(fromText: subject.isEmpty ? "(No Subject)" : subject))</h2>"
        for (i, original) in emails.enumerated() {
            let email = decrypted[original.id].map { $0.shown(in: original) } ?? original
            var lines: [String] = []
            if let from = email.from, !from.isEmpty { lines.append("<b>From:</b> " + Draft.html(fromText: from.map(\.formatted).joined(separator: ", "))) }
            if let to = email.to, !to.isEmpty { lines.append("<b>To:</b> " + Draft.html(fromText: to.map(\.formatted).joined(separator: ", "))) }
            if let cc = email.cc, !cc.isEmpty { lines.append("<b>Cc:</b> " + Draft.html(fromText: cc.map(\.formatted).joined(separator: ", "))) }
            if let date = email.receivedAt { lines.append("<b>Date:</b> " + Draft.html(fromText: date.formatted(date: .long, time: .shortened))) }
            if i > 0 { out += "<hr style=\"border:none;border-top:1px solid #ccc;margin:18px 0\">" }
            out += "<div style=\"font-size:12px;color:#555;margin-bottom:10px\">\(lines.joined(separator: "<br>"))</div>"
            let body = email.html.map { Trackers.strip($0).html } ?? "<div style=\"white-space:pre-wrap\">\(Draft.html(fromText: email.text))</div>"
            out += "<div>\(body)</div>"
            let files = email.files.compactMap(\.name)
            if !files.isEmpty { out += "<p style=\"font-size:12px;color:#555\"><b>Attachments:</b> \(Draft.html(fromText: files.joined(separator: ", ")))</p>" }
        }
        // Printed in black on white, whatever the screen's appearance.
        return MessageWebView.document(out, allowRemote: false)
    }

    @MainActor
    final class Job: NSObject, WKNavigationDelegate {
        private let view: WKWebView
        private let html: String
        private let title: String
        private var finished: ((Job) -> Void)?

        init(html: String, title: String) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            // A page's width, so the layout is the printed one; it's never on screen.
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: config)
            // Dark text on white paper, even in dark mode.
            view.appearance = NSAppearance(named: .aqua)
            self.html = html
            self.title = title
        }

        func start(_ finished: @escaping (Job) -> Void) {
            self.finished = finished
            view.navigationDelegate = self
            view.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            let operation = webView.printOperation(with: info)
            operation.jobTitle = title
            // WebKit's print view needs a size before it can lay out pages.
            operation.view?.frame = webView.bounds
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                operation.runModal(for: window, delegate: self, didRun: #selector(printed), contextInfo: nil)
            } else {
                operation.run()
                finished?(self)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }

        @objc private func printed(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            finished?(self)
        }
    }
}
