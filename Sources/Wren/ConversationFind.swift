import SwiftUI
import WrenKit

/// A conversation's messages, oldest first, as the reader and conversation windows show them: older read messages
/// fold to one line (click to open them), and Find (⌘F, then ⌘G and ⇧⌘G) looks through every message and marks
/// what it finds.
struct ConversationMessages: View {
    let thread: [Email]
    /// Messages that stay open (unread when the conversation was opened).
    var keepOpen: Set<String> = []
    @State private var opened: Set<String> = []
    @State private var finding = false
    @State private var query = ""
    /// Matches in each message, as each reports them.
    @State private var counts: [String: Int] = [:]
    /// Which match is current, across the whole conversation.
    @State private var current = 0
    @FocusState private var findFocused: Bool

    private var searching: String { finding ? query.trimmingCharacters(in: .whitespaces) : "" }
    private var total: Int { thread.reduce(0) { $0 + (counts[$1.id] ?? 0) } }

    /// The message holding the current match, and its place among that message's matches.
    private var located: (id: String, index: Int)? {
        var left = current
        for email in thread {
            let n = counts[email.id] ?? 0
            if left < n { return (email.id, left) }
            left -= n
        }
        return nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The conversation's subject is its first message's; later ones only add "Re:".
                    if let first = thread.first {
                        Text((first.subject ?? "").isEmpty ? "(No Subject)" : first.subject!)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 4)
                    }
                    ForEach(thread) { email in
                        // An invitation still waiting for an answer stays open, however old; while finding, all do.
                        let waiting = email.invite.map { $0.canReply == true && !$0.isCancelled && $0.answer == nil } ?? false
                        let expanded = !searching.isEmpty || email.id == thread.last?.id || opened.contains(email.id) || keepOpen.contains(email.id) || waiting
                        MessageView(email: email, expanded: expanded) {
                            if opened.contains(email.id) { opened.remove(email.id) } else { opened.insert(email.id) }
                        }
                        .environment(\.find, searching.isEmpty ? nil : FindRequest(
                            query: searching,
                            current: located?.id == email.id ? located?.index : nil,
                            report: { count, located in
                                if counts[email.id] != count { counts[email.id] = count }
                                if located { scroll(proxy) }
                            }
                        ))
                        if email.id != thread.last?.id { Divider().padding(.leading, 66) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if finding { findBar(proxy) }
            }
            .onChange(of: searching) {
                counts = [:]
                current = 0
            }
            // A plain-text message knows where its match is straight away; a web page says (see `report`).
            .onChange(of: current) { scroll(proxy) }
        }
        // ⌘F, ⌘G and ⇧⌘G while this window is in front. Kept in the view rather than the Edit menu, so text fields
        // (the search field, a message being written) keep their own Find.
        .background {
            if !thread.isEmpty {
                Group {
                    Button("Find in Conversation") {
                        finding = true
                        findFocused = true
                    }
                    .keyboardShortcut("f")
                    Button("Find Next") { step(1) }.keyboardShortcut("g")
                    Button("Find Previous") { step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if thread.isEmpty { ProgressView() }
        }
    }

    private func findBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in Conversation", text: $query)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { step(1) }
            if !searching.isEmpty {
                Text(total == 0 ? "Not found" : "\(min(current + 1, total)) of \(total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ControlGroup {
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous (⇧⌘G)")
                    .accessibilityLabel("Previous match")
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .help("Next (⌘G)")
                    .accessibilityLabel("Next match")
            }
            .disabled(total == 0)
            .fixedSize()
            Button("Done") { close() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { close() }
    }

    private func step(_ by: Int) {
        guard total > 0 else { return }
        current = (current + by + total) % total
    }

    private func close() {
        finding = false
        query = ""
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        // After the marker for the new match has been laid out.
        Task { @MainActor in
            await Task.yield()
            withAnimation(MailStore.motion) { proxy.scrollTo(FindRequest.marker, anchor: .center) }
        }
    }
}

/// What Find is looking for in one message: the words, which of this message's matches is current (if any), and
/// where to report how many it found (and when the current one has been placed, to scroll to it).
struct FindRequest {
    var query: String
    var current: Int?
    var report: (_ count: Int, _ located: Bool) -> Void

    /// The id of the view marking the current match, to scroll to.
    static let marker = "find-current"

    /// Where the words are in some plain text, ignoring case.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }
}

extension EnvironmentValues {
    @Entry var find: FindRequest? = nil
}
