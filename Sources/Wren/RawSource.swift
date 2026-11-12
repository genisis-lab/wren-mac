import AppKit
import SwiftUI
import WrenKit

/// Which message's raw source a window shows.
struct RawSourceKey: Codable, Hashable {
    var place: MailboxRef
    var blobId: String
    var subject: String
}

/// A message exactly as it arrived (View Raw Source): every header, and the body as sent. Handy for checking where
/// a suspicious message really came from.
struct RawSourceWindow: View {
    @Binding var value: RawSourceKey?
    @Environment(MailStore.self) private var store
    @State private var text: String?
    @State private var problem: String?

    var body: some View {
        Group {
            if let text {
                SourceText(text: text)
            } else if let problem {
                ContentUnavailableView("Can’t Show the Source", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Source: " + ((value?.subject).flatMap { $0.isEmpty ? nil : $0 } ?? "Message"))
        .toolbar {
            ToolbarItem {
                Button { save() } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
                    .help("Save to Downloads as an .eml file")
                    .disabled(text == nil)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task(id: value) { await load() }
    }

    private func load() async {
        guard let value else { return }
        do {
            let data = try await store.download(BodyPart(blobId: value.blobId, size: 0, name: "message.eml", type: "message/rfc822"), in: value.place)
            // Mail is mostly ASCII; anything else shows as Latin-1 rather than not at all.
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() {
        guard let text, let value else { return }
        let name = value.subject.trimmingCharacters(in: .whitespaces)
        store.saveToDownloads((name.isEmpty ? "Message" : name) + ".eml", Data(text.utf8))
    }
}

/// Monospaced, selectable and fast with big messages (a text view, not SwiftUI Text).
private struct SourceText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.string = text
        view.setAccessibilityLabel("Message source")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text { view.string = text }
    }
}
