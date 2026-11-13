import AppKit
import SwiftUI
import WebKit
import WrenKit

@main struct MessageWebViewRegression {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let endpoints = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let target = endpoints["target"]!, source = endpoints["source"]!
        let html = """
        <p id="safe">An ordinary message</p>
        <script>document.body.dataset.executed = 'yes'; fetch('\(target)/script');</script>
        <img src="\(target)/image" onerror="document.body.dataset.executed='yes'">
        <style>body { background-image: url('\(target)/style'); }</style>
        <iframe src="\(target)/frame"></iframe>
        <meta http-equiv="refresh" content="0;url=\(target)/refresh">
        <form action="\(target)/form"><input name="secret" value="fake"></form>
        """
        let reader = MessageWebView(html: html, allowRemote: false, inline: [], download: { _ in Data() }, openLink: { _ in
            preconditionFailure("Message opened a link without a click")
        }, height: .constant(400))
        let host = NSHostingView(rootView: reader)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // A hidden, synthetic reader; no mailbox data or user interaction.
        host.layoutSubtreeIfNeeded()
        var web: WKWebView?
        for _ in 0..<100 {
            web = findWebView(host)
            if let web, !web.isLoading,
               (try? await web.callAsyncJavaScript("return document.getElementById('safe')?.textContent", in: nil, contentWorld: .defaultClient)) as? String == "An ordinary message" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let web else { fatalError("Reader did not create its web view") }
        precondition(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let text = try await web.callAsyncJavaScript("return document.getElementById('safe')?.textContent", in: nil, contentWorld: .defaultClient) as? String
        precondition(text == "An ordinary message", "Benign content did not render")
        let ran = try await web.callAsyncJavaScript("return document.body.dataset.executed || 'no'", in: nil, contentWorld: .defaultClient) as? String
        precondition(ran == "no", "An email script executed")
        _ = try? await web.callAsyncJavaScript("document.querySelector('form').submit()", in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(500))
        let (data, _) = try await URLSession.shared.data(from: URL(string: source + "/hits")!)
        let hits = try JSONDecoder().decode([String: Int].self, from: data)
        precondition(hits["count"] == 0, "An email contacted the remote test server")
        print("Message reader checks passed: content rendered; scripts, remote resources, refresh and forms blocked.")
        // Keep the hosting window alive through the checks.
        withExtendedLifetime(window) {}
    }

    @MainActor static func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { findWebView($0) }.first
    }
}
