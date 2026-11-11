import AppKit
import UniformTypeIdentifiers

/// Share → Wren: a new message in Wren with the files that were shared, or with the link and text.
/// Nothing is shown here; Wren opens the message.
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await share() }
    }

    private func share() async {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        var files: [URL] = []
        var lines: [String] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if let url = await url(provider) {
                if url.isFileURL { files.append(url) } else { lines.append(url.absoluteString) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                lines.append(text)
            }
        }
        // The extension is in Wren.app/Contents/PlugIns, and opens things with its own app whatever the default is.
        let wren = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let open = NSWorkspace.OpenConfiguration()
        // Files become one message with them attached, as when they're dropped on Wren's Dock icon.
        // shortcut: text shared along with files is left out; send both when an app is found that shares both.
        if !files.isEmpty {
            _ = try? await NSWorkspace.shared.open(files, withApplicationAt: wren, configuration: open)
        } else if !lines.isEmpty {
            let subject = items.first?.attributedTitle?.string ?? ""
            let link = "mailto:?subject=\(Self.encoded(subject))&body=\(Self.encoded(lines.joined(separator: "\n\n")))"
            if let url = URL(string: link) { _ = try? await NSWorkspace.shared.open([url], withApplicationAt: wren, configuration: open) }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// A file or a web link (a file's URL is a URL too).
    private func url(_ provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
              let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) else { return nil }
        if let url = item as? URL { return url }
        return (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
    }

    /// For a mailto: link: everything but unreserved ASCII percent-encoded, so & and = in the text stay text.
    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}
