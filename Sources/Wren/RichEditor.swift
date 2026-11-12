import AppKit
import SwiftUI
import WebKit

/// Which formatting applies where the caret is, for the format bar.
struct FormatState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var bullets = false
    var numbers = false
    var quote = false
}

/// The message editor: formatted text in a web view, as in Mail. The page's own scripts are off, so nothing in a
/// quoted message runs; the editor's script runs in the app's own script world. Nothing loads from the web.
struct RichEditor: NSViewRepresentable {
    /// What to start with (read once; give the view a new id to start over).
    let html: String
    let startFocused: Bool
    let controller: EditorController
    @Binding var state: FormatState
    let onChange: (String) -> Void
    /// Files dropped on the editor, to attach (not to put in the text).
    let onFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let scripts = config.userContentController
        scripts.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: controller.world))
        scripts.add(context.coordinator, contentWorld: controller.world, name: "html")
        scripts.add(context.coordinator, contentWorld: controller.world, name: "state")
        let view = EditorWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.onFiles = onFiles
        view.setAccessibilityLabel("Message")
        controller.view = view
        view.loadHTMLString(Self.document(html), baseURL: nil)
        return view
    }

    func updateNSView(_ view: EditorWebView, context: Context) {
        context.coordinator.parent = self
        view.onFiles = onFiles
    }

    static func document(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'">
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; height: 100%; background: -apple-system-text-background; }
        body { font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; color: -apple-system-label; }
        #wren-editor { box-sizing: border-box; min-height: 100%; padding: 8px 16px 24px; outline: none; word-wrap: break-word; }
        blockquote { margin: 0 0 0 4px; padding-left: 12px; border-left: 2px solid -apple-system-separator; color: -apple-system-secondary-label; }
        img { max-width: 100%; height: auto; }
        a { color: -apple-system-blue; }
        </style></head><body><div id="wren-editor" contenteditable="true" role="textbox" aria-multiline="true" aria-label="Message" spellcheck="true">\(html)</div></body></html>
        """
    }

    /// The editor's side: reports the HTML as it changes and which formats apply, and runs the format bar's commands.
    private static let script = """
    (() => {
      const ed = document.getElementById('wren-editor');
      if (!ed) return;
      const send = () => webkit.messageHandlers.html.postMessage(ed.innerHTML);
      const quoteAround = () => {
        for (let n = getSelection().anchorNode; n && n !== ed; n = n.parentNode) if (n.nodeName === 'BLOCKQUOTE') return n;
        return null;
      };
      const on = (c) => { try { return document.queryCommandState(c); } catch { return false; } };
      const report = () => webkit.messageHandlers.state.postMessage({
        bold: on('bold'), italic: on('italic'), underline: on('underline'),
        bullets: on('insertUnorderedList'), numbers: on('insertOrderedList'), quote: !!quoteAround(),
      });
      ed.addEventListener('input', send);
      // A picture alone on the clipboard would be a broken image in the sent message; attach it instead.
      ed.addEventListener('paste', (e) => {
        const types = [...(e.clipboardData?.types ?? [])];
        if (types.includes('Files') && !types.includes('text/html') && !types.includes('text/plain')) e.preventDefault();
      });
      document.addEventListener('selectionchange', report);
      let saved = null;
      const restore = () => {
        ed.focus();
        if (!saved) return;
        const s = getSelection();
        s.removeAllRanges();
        s.addRange(saved);
        saved = null;
      };
      const esc = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
      window.wrenEditor = {
        run(command) { restore(); document.execCommand(command, false, null); send(); report(); },
        quote() {
          restore();
          const q = quoteAround();
          // shortcut: taking a quote away isn't in the editor's undo; use execCommand if that's missed.
          if (q) { while (q.firstChild) q.parentNode.insertBefore(q.firstChild, q); q.remove(); }
          else document.execCommand('formatBlock', false, 'blockquote');
          send(); report();
        },
        save() {
          const s = getSelection();
          saved = s.rangeCount && ed.contains(s.anchorNode) ? s.getRangeAt(0).cloneRange() : null;
        },
        link(url) {
          restore();
          if (getSelection().isCollapsed) document.execCommand('insertHTML', false, '<a href="' + esc(url) + '">' + esc(url) + '</a>');
          else document.execCommand('createLink', false, url);
          send();
        },
        // Another From address: its signature in place of the last one (or added above the quote, if there was none).
        signature(html) {
          let sig = ed.querySelector('.wren-signature');
          if (!html) { if (sig) sig.remove(); send(); return; }
          if (!sig) {
            sig = document.createElement('div');
            sig.className = 'wren-signature';
            const quote = ed.querySelector('.wren-quote');
            for (const n of [document.createElement('br'), document.createElement('br'), sig]) ed.insertBefore(n, quote);
          }
          sig.innerHTML = html;
          send();
        },
        focusStart() {
          ed.focus();
          const r = document.createRange();
          r.setStart(ed, 0);
          r.collapse(true);
          const s = getSelection();
          s.removeAllRanges();
          s.addRange(r);
        },
      };
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichEditor

        init(_ parent: RichEditor) {
            self.parent = parent
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "html", let html = message.body as? String {
                parent.onChange(html)
            } else if message.name == "state", let s = message.body as? [String: Bool] {
                let state = FormatState(
                    bold: s["bold"] ?? false, italic: s["italic"] ?? false, underline: s["underline"] ?? false,
                    bullets: s["bullets"] ?? false, numbers: s["numbers"] ?? false, quote: s["quote"] ?? false
                )
                if state != parent.state { parent.state = state }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard parent.startFocused else { return }
            webView.window?.makeFirstResponder(webView)
            parent.controller.call("wrenEditor.focusStart()")
        }

        /// Only the editor's own page: links in the text don't go anywhere while you write.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == "about" && navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}

/// Sends the format bar's commands to the editor.
@MainActor
final class EditorController {
    weak var view: WKWebView?
    let world = WKContentWorld.world(name: "editor")

    func call(_ code: String, _ arguments: [String: Any] = [:]) {
        view?.callAsyncJavaScript(code, arguments: arguments, in: nil, in: world, completionHandler: nil)
    }

    /// Formatting applies where you're typing: not when a shortcut is pressed in the To or Subject field.
    private var isTyping: Bool {
        guard let view, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func run(_ command: String) { if isTyping { call("wrenEditor.run(command)", ["command": command]) } }
    func toggleQuote() { if isTyping { call("wrenEditor.quote()") } }
    /// Swap the signature (HTML from `Draft.signatureInner`; empty takes it away).
    func setSignature(_ html: String) { call("wrenEditor.signature(html)", ["html": html]) }
    func saveSelection() { call("wrenEditor.save()") }

    func link(_ text: String) {
        guard let url = Self.linkURL(text) else { return }
        call("wrenEditor.link(url)", ["url": url.absoluteString])
    }

    /// What's typed as a link: web and mail addresses only (never javascript: and the like).
    static func linkURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains(":") { text = (text.contains("@") && !text.contains("/") ? "mailto:" : "https://") + text }
        guard let url = URL(string: text), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// Files dropped on the editor are attached to the message, as anywhere else on the window.
final class EditorWebView: WKWebView {
    var onFiles: ([URL]) -> Void = { _ in }

    private func files(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFiles(urls)
        return true
    }
}

/// Bold, italic, underline, links, lists and quotes for the editor, with the usual keyboard shortcuts.
struct FormatBar: View {
    let state: FormatState
    let editor: EditorController
    @State private var linking = false
    @State private var link = ""

    var body: some View {
        HStack(spacing: 2) {
            button("Bold", "bold", on: state.bold, key: "b") { editor.run("bold") }
            button("Italic", "italic", on: state.italic, key: "i") { editor.run("italic") }
            button("Underline", "underline", on: state.underline, key: "u") { editor.run("underline") }
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("Add Link", "link", on: false, key: "k") {
                editor.saveSelection()
                link = ""
                linking = true
            }
            button("Bulleted List", "list.bullet", on: state.bullets, key: "7", shift: true) { editor.run("insertUnorderedList") }
            button("Numbered List", "list.number", on: state.numbers, key: "8", shift: true) { editor.run("insertOrderedList") }
            button("Quote", "text.quote", on: state.quote, key: "'") { editor.toggleQuote() }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .alert("Add Link", isPresented: $linking) {
            TextField("Web or email address", text: $link)
            Button("Add") { editor.link(link) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Selected text becomes the link; otherwise the address is added.")
        }
    }

    private func button(_ title: String, _ symbol: String, on: Bool, key: Character, shift: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 20)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(on ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(KeyEquivalent(key), modifiers: shift ? [.command, .shift] : .command)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
