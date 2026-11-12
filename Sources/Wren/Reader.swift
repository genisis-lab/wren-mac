import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WrenKit

struct ReaderPane: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch store.selectedThreads.count {
            case 0: ContentUnavailableView("No Message Selected", systemImage: "envelope")
            case 1: ConversationView().id(store.threadId)
            default: ContentUnavailableView("\(store.selectedThreads.count) Conversations Selected", systemImage: "tray.full")
            }
        }
        .task(id: store.selectedThreads) {
            await store.open(store.selectedThreads.count == 1 ? store.selectedThreads.first : nil)
        }
        .focusedSceneValue(\.printable, store.selectedThreads.count == 1 && !store.thread.isEmpty ? Printable(emails: store.thread) : nil)
        .toolbar { actions }
    }

    private func compose(_ draft: Draft?) {
        if let draft { openWindow(id: "compose", value: draft) }
    }

    private func act(_ action: @escaping (MailStore, Set<String>) async -> Void) {
        let ids = store.selectedThreads
        Task { await action(store, ids) }
    }

    @ToolbarContentBuilder
    private var actions: some ToolbarContent {
        let role = store.currentRole ?? ""
        let none = store.selectedThreads.isEmpty
        ToolbarItemGroup {
            // In Archive, Trash and Snoozed the first button takes mail back to the Inbox instead.
            if store.canMoveToInbox {
                Button { act { await $0.moveToInbox($1) } } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
                    .help("Move to Inbox")
                    .disabled(none)
            } else {
                Button { act { await $0.archive($1) } } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive")
                    .disabled(none || ["drafts", "sent"].contains(role))
            }
            Button { act { await $0.trash($1) } } label: { Label(role == "trash" ? "Delete Forever" : "Trash", systemImage: "trash") }
                .help(role == "trash" ? "Delete Forever" : "Move to Trash")
                .disabled(none)
            Button { act { await $0.junk($1) } } label: { Label(role == "junk" ? "Not Junk" : "Junk", systemImage: role == "junk" ? "tray.and.arrow.up" : "xmark.bin") }
                .help(role == "junk" ? "Not Junk" : "Move to Junk")
                .disabled(none || ["drafts", "sent"].contains(role))
        }
        ToolbarItemGroup {
            Button { compose(store.replyDraft(all: false)) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .help("Reply")
                .disabled(!store.canReply)
            Button { compose(store.replyDraft(all: true)) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                .help("Reply All")
                .disabled(!store.canReply)
            Button { compose(store.forwardDraft()) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward")
                .disabled(!store.canReply)
        }
        ToolbarItemGroup {
            let flagged = store.selectionIsFlagged
            Button { act { await $0.toggleFlag($1) } } label: { Label(flagged ? "Unflag" : "Flag", systemImage: flagged ? "flag.slash" : "flag") }
                .help(flagged ? "Unflag" : "Flag")
                .disabled(none)
            Menu {
                ForEach(SnoozeTime.choices(), id: \.title) { choice in
                    Button(choice.title) { act { await $0.snooze($1, until: choice.date) } }
                }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .help("Snooze")
            .disabled(none || !store.canSnooze)
        }
    }
}

/// The conversation open in the reader.
struct ConversationView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        ConversationMessages(thread: store.thread, keepOpen: store.unreadWhenOpened)
    }
}

struct MessageView: View {
    let email: Email
    let expanded: Bool
    let toggle: () -> Void
    @Environment(MailStore.self) private var store
    @Environment(\.conversationPlace) private var windowPlace
    @Environment(\.openWindow) private var openWindow
    @AppStorage("loadRemoteContent") private var loadRemoteAlways = false
    @State private var loadRemote = false

    private var sender: EmailAddress? { email.from?.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                header
                if expanded { messageMenu }
            }

            if expanded {
                if email.isDraft, let draft = store.editDraft(email, in: windowPlace) {
                    Button("Edit Draft") { openWindow(id: "compose", value: draft) }
                }
                if let invite = email.invite { InviteCard(email: email, invite: invite) }
                if email.canUnsubscribe == true, !email.isDraft, email.unsubscribed == true || store.canSend(in: windowPlace) { UnsubscribeRow(email: email) }
                if let kind = PGPKind(email) {
                    PGPMessageView(email: email, kind: kind)
                } else {
                    plainMessage
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// A message without PGP, its remote content hidden until asked for.
    @ViewBuilder
    private var plainMessage: some View {
        let allowRemote = loadRemote || loadRemoteAlways
        // Tracking pictures are taken out before anything else sees the message.
        let content = email.html.map(Trackers.strip)
        if let html = content?.html, !allowRemote, hasRemoteContent(html) {
            HStack {
                Label("Remote content is hidden to protect your privacy.", systemImage: "eye.slash")
                Spacer()
                Button("Load Remote Content") { loadRemote = true }
            }
            .font(.callout)
            .padding(10)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
        if let removed = content?.removed, removed > 0 {
            Label(removed == 1 ? "1 tracker blocked" : "\(removed) trackers blocked", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Wren removed pictures whose only job is to tell the sender when you open the message.")
        }
        MessageBody(email: email, html: content?.html, allowRemote: allowRemote)
        if !email.files.isEmpty { AttachmentList(files: email.files) }
    }

    /// Who, when and to whom; click to fold or open the message.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(address: sender)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender?.displayName ?? "Unknown Sender")
                        .font(.headline)
                    if email.isDraft {
                        Text("Draft").font(.caption.weight(.medium)).foregroundStyle(.red)
                    }
                    Spacer()
                    Text(email.receivedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if expanded {
                    // The address itself, not just the name, so a lookalike sender is easy to spot.
                    if let address = sender?.email, address != sender?.displayName {
                        Text(address).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    recipients("To", email.to)
                    recipients("Cc", email.cc)
                } else {
                    Text(email.preview ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(expanded ? "Folds this message" : "Shows this message")
    }

    @ViewBuilder
    private func recipients(_ label: String, _ list: [EmailAddress]?) -> some View {
        if let list, !list.isEmpty {
            Text("\(label): " + list.map(\.displayName).joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(list.map(\.formatted).joined(separator: ", "))
        }
    }

    /// Reply, Reply All and Forward for this message (the toolbar's act on the newest).
    private var messageMenu: some View {
        Menu {
            Button("Reply") { if let d = store.replyDraft(to: email, all: false, in: windowPlace) { openWindow(id: "compose", value: d) } }
            Button("Reply All") { if let d = store.replyDraft(to: email, all: true, in: windowPlace) { openWindow(id: "compose", value: d) } }
            Button("Forward") { if let d = store.forwardDraft(of: email, in: windowPlace) { openWindow(id: "compose", value: d) } }
            Divider()
            Button("Raw Source") { if let key = store.sourceKey(of: email, in: windowPlace) { openWindow(id: "source", value: key) } }
                .disabled(email.blobId == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Message actions")
    }
}

/// List mail: unsubscribe from here, as on the web. Wren asks the list or writes to it; a list that only has a
/// page for it gets that page opened.
struct UnsubscribeRow: View {
    let email: Email
    @Environment(MailStore.self) private var store
    @Environment(\.conversationPlace) private var windowPlace
    @State private var working = false
    @State private var note: String?

    var body: some View {
        HStack {
            if note != nil || email.unsubscribed == true {
                Label(note ?? "You unsubscribed from this sender.", systemImage: "checkmark.circle")
            } else {
                Label("This is from a mailing list.", systemImage: "newspaper")
                Spacer()
                Button("Unsubscribe") { unsubscribe() }
                    .disabled(working)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func unsubscribe() {
        working = true
        Task {
            defer { working = false }
            do {
                let done = try await store.unsubscribe(email, in: windowPlace)
                switch done.method {
                case "link":
                    if let url = done.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                    note = "Finish unsubscribing on the page that opened."
                case "email": note = "Wren sent the list a request to unsubscribe you."
                default: note = "You’re unsubscribed."
                }
            } catch {
                store.alert = error.localizedDescription
            }
        }
    }
}

/// Whether an HTML body loads anything from the web (images, styles, fonts).
func hasRemoteContent(_ html: String) -> Bool {
    html.range(of: #"(?i)(\bsrc|\bsrcset|\bbackground|<link\b[^>]*\bhref)\s*=\s*["']?\s*(https?:)?//|url\(\s*["']?\s*(https?:)?//"#, options: .regularExpression) != nil
}

struct MessageBody: View {
    let email: Email
    /// The HTML to show, trackers taken out (nil for a plain-text message).
    let html: String?
    let allowRemote: Bool
    @Environment(MailStore.self) private var store
    @Environment(\.conversationPlace) private var windowPlace
    @Environment(\.find) private var find
    @AppStorage(ReaderTextSize.key) private var textSize = 1.0
    @State private var height: CGFloat = 80
    /// Where Find's current match is, from the top of the message.
    @State private var matchY: CGFloat = 0

    var body: some View {
        Group {
            if let html {
                MessageWebView(
                    html: html, allowRemote: allowRemote, inline: email.attachments ?? [],
                    download: { [store, windowPlace] in try await store.download($0, in: windowPlace) }, openLink: open, height: $height,
                    zoom: textSize, find: find?.query ?? "", findCurrent: find?.current,
                    onFound: { [find] count, y in
                        if let y { matchY = y }
                        find?.report(count, y != nil)
                    }
                )
                .frame(height: height)
                // Mail with colors of its own sits on its own page.
                .clipShape(RoundedRectangle(cornerRadius: MessageWebView.followsAppearance(html) ? 0 : 8))
                .accessibilityLabel("Message")
            } else {
                Text(linked(email.text, marking: find))
                    .font(.system(size: NSFont.systemFontSize * textSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        open(url)
                        return .handled
                    })
                    .task(id: "\(find?.query ?? "") \(find?.current ?? -1)") {
                        guard let find else { return }
                        matchY = 0
                        find.report(FindRequest.ranges(of: find.query, in: email.text).count, find.current != nil)
                    }
            }
        }
        // Find scrolls here: the current match (or, in plain text, the top of the message holding it).
        .overlay(alignment: .topLeading) {
            if find?.current != nil {
                Color.clear.frame(width: 1, height: 1).padding(.top, matchY).id(FindRequest.marker)
            }
        }
    }

    /// Links open in the browser without their tracking; email addresses start a message here.
    private func open(_ url: URL) {
        if url.scheme?.lowercased() == "mailto" {
            store.openMailto(url)
        } else {
            NSWorkspace.shared.open(Trackers.clean(url))
        }
    }

    private func linked(_ text: String, marking find: FindRequest?) -> AttributedString {
        var s = AttributedString(text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let range = Range(match.range, in: s) { s[range].link = url }
            }
        }
        // Find's matches, marked as in a web page: the current one orange.
        if let find {
            for (i, r) in FindRequest.ranges(of: find.query, in: text).enumerated() {
                guard let range = Range(NSRange(r, in: text), in: s) else { continue }
                s[range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = i == find.current ? Color.orange : Color.yellow.opacity(0.6)
                s[range][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.black
            }
        }
        return s
    }
}

struct Avatar: View {
    let address: EmailAddress?
    private static let colors: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .green, .teal, .cyan, .brown]

    var body: some View {
        let name = address?.displayName ?? "?"
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        // A stable color per address (hashValue changes between launches).
        let index = (address?.email.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) } ?? 0) % Self.colors.count
        Circle()
            .fill(Self.colors[index].gradient)
            .frame(width: 36, height: 36)
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Files under a message, as in Mail: click to select, Space for Quick Look, double-click to open,
/// or drag one out to the Finder.
struct AttachmentList: View {
    let files: [BodyPart]
    @Environment(MailStore.self) private var store
    @Environment(\.conversationPlace) private var windowPlace
    @FocusState private var selected: BodyPart?
    @State private var preview: URL?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(files, id: \.self) { file in
                let name = file.name ?? "Attachment"
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: file.type) ?? .data))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Text(Int64(file.size).formatted(.byteCount(style: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected == file ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .focusable()
                .focused($selected, equals: file)
                .focusEffectDisabled()
                .onTapGesture(count: 2) { Task { await store.openAttachment(file, in: windowPlace) } }
                .onTapGesture { selected = file }
                .onKeyPress(.space) {
                    quickLook(file)
                    return .handled
                }
                .draggable(DraggedAttachment(part: file, account: store.fileSource(in: windowPlace)?.account ?? "", client: store.fileSource(in: windowPlace)?.client))
                .help(name)
                .contextMenu {
                    Button("Open") { Task { await store.openAttachment(file, in: windowPlace) } }
                    Button("Quick Look") { quickLook(file) }
                    Button("Save to Downloads") { Task { await store.saveAttachment(file, in: windowPlace) } }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { Task { await store.openAttachment(file, in: windowPlace) } }
                .accessibilityAction(named: "Quick Look") { quickLook(file) }
            }
        }
        .quickLookPreview($preview)
    }

    /// Space opens Quick Look and closes it again.
    private func quickLook(_ file: BodyPart) {
        selected = file
        if preview != nil {
            preview = nil
            return
        }
        Task {
            do {
                preview = try await store.temporaryFile(file, in: windowPlace)
            } catch {
                store.alert = error.localizedDescription
            }
        }
    }
}

/// An attachment dragged out of a message: downloaded when it's dropped.
struct DraggedAttachment: Transferable, Sendable {
    let part: BodyPart
    let account: String
    let client: JMAPClient?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            guard let client = item.client else { throw NotConnected() }
            return SentTransferredFile(try await MailStore.temporaryFile(item.part, account: item.account, client: client))
        }
        .suggestedFileName { $0.part.name ?? "Attachment" }
    }
}
