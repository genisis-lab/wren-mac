import Foundation

/// Tracking in mail: pictures that tell the sender you opened a message, and links that tell them who clicked.
/// The same rules as Wren on the web (src/web/lib/sanitize.ts).
public enum Trackers {
    /// Query parameters that only record who clicked; no site needs them to work. utm_* too.
    static let params: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "ttclid", "li_fat_id", "yclid", "igshid",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsCtaTracking", "mkt_tok",
        "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "_kx", "ck_subscriber_id",
    ]

    /// Redirect pages that carry the real address in a query parameter: host, path, parameters.
    static let redirects: [(host: String, path: String, params: [String])] = [
        (#"^(www\.)?google\.(com|[a-z]{2}|com?\.[a-z]{2})$"#, #"^/url$"#, ["q", "url"]),
        (#"\.safelinks\.protection\.outlook\.com$"#, #"^/"#, ["url"]),
        (#"^(l|lm)\.facebook\.com$|^l\.messenger\.com$"#, #"^/l\.php$"#, ["u"]),
        (#"^l\.instagram\.com$"#, #"^/$"#, ["u"]),
        (#"^(www\.)?youtube\.com$"#, #"^/redirect$"#, ["q"]),
    ]

    /// Well-known email open trackers, matched against host + path.
    static let images = [
        #"(^|\.)list-manage\.com/track/open"#, // Mailchimp
        #"(^|\.)mandrillapp\.com/track/open"#, // Mandrill
        #"/wf/open$"#, // SendGrid, on the sender's own link domain
        #"(^|\.)awstrack\.me/"#, // Amazon SES
        #"/__ptq\.gif$"#, // HubSpot
        #"(^|\.)exct\.net/open\.aspx"#, // Salesforce Marketing Cloud
        #"(^|\.)rs6\.net/on\.jsp"#, // Constant Contact
        #"(^|\.)mailtrack\.io/trace"#, // Mailtrack
        #"(^|\.)t\.yesware\.com/"#, // Yesware
        #"(^|\.)mailfoogae\.appspot\.com/"#, // Streak
    ]

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// An http(s) address as a browser reads it, or nil.
    static func webURL(_ text: String) -> URLComponents? {
        var t = text.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x20)))
        if t.hasPrefix("//") { t = "https:" + t }
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https", c.host?.isEmpty == false else { return nil }
        return c
    }

    /// Where a web link really goes: known redirect wrappers unwrapped and tracking parameters dropped.
    /// Anything else, or a link with nothing to clean, comes back as it was.
    public static func clean(_ url: URL) -> URL {
        guard var c = webURL(url.absoluteString) else { return url }
        var changed = false
        for _ in 0..<3 {
            let host = c.host?.lowercased() ?? ""
            guard let wrapper = redirects.first(where: { matches(host, $0.host) && matches(c.percentEncodedPath, $0.path) }),
                  let inner = wrapper.params.lazy.compactMap({ p in c.queryItems?.first { $0.name == p }?.value }).first(where: { !$0.isEmpty }).flatMap(webURL)
            else { break }
            c = inner
            changed = true
        }
        if let query = c.percentEncodedQuery {
            // Filtered by hand so the parameters that stay keep their exact encoding.
            let parts = query.split(separator: "&", omittingEmptySubsequences: false)
            // Marketo's unsubscribe and view-in-browser pages need mkt_tok to know who's asking.
            let marketo = matches(c.percentEncodedPath + "?" + query, "(?i)unsubscribe|emailWebview")
            let kept = parts.filter { part in
                let key = String(part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                return !matches(key, "(?i)^utm_") && (!params.contains(key) || (key == "mkt_tok" && marketo))
            }
            if kept.count < parts.count {
                c.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
                changed = true
            }
        }
        return changed ? (c.url ?? url) : url
    }

    /// The message without its tracking pictures, and how many there were. They're left out even when
    /// remote content is loaded, so opening a message never reports back.
    /// shortcut: reads <img> tags with a regular expression and skips trackers in CSS backgrounds; parse the HTML if senders start dodging it.
    public static func strip(_ html: String) -> (html: String, removed: Int) {
        guard let tag = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]) else { return (html, 0) }
        var out = html
        var removed = 0
        for match in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let range = Range(match.range, in: html), isTrackingPixel(String(html[range])) else { continue }
            out.replaceSubrange(range, with: "")
            removed += 1
        }
        return (out, removed)
    }

    /// The value of an attribute in an HTML tag, entities for & undone.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?is)\\s\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        for i in 1...3 {
            if let r = Range(m.range(at: i), in: tag) { return tag[r].replacingOccurrences(of: "&amp;", with: "&") }
        }
        return nil
    }

    /// A remote picture whose only job is to tell the sender the email was opened: 0–2px (CSS beats the
    /// width/height attributes, as in the browser), hidden, or from a known tracker. A hidden picture with a
    /// real size stays: responsive mail hides its phone-only pictures and shows them with @media rules.
    static func isTrackingPixel(_ tag: String) -> Bool {
        guard let src = attribute("src", in: tag), let url = webURL(src) else { return false } // embedded pictures can't report back
        let style = (attribute("style", in: tag) ?? "").lowercased()
        func size(_ name: String) -> Double? {
            let css = style.range(of: "(?:^|;)\\s*\(name)\\s*:([^;]*)", options: .regularExpression).map { String(style[$0]) }
                .map { $0.drop { $0 != ":" }.dropFirst().replacingOccurrences(of: "!important", with: "") }
            guard let v = (css ?? attribute(name, in: tag))?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return nil }
            return matches(v, "^[0-9.]+(px)?$") ? Double(v.replacingOccurrences(of: "px", with: "")) ?? .nan : .nan // NaN: 100%, auto…
        }
        let dims = [size("width"), size("height")].compactMap { $0 }
        let tiny = !dims.isEmpty && dims.allSatisfy { $0 <= 2 }
        // The bare attribute, not the word inside some other attribute's value.
        let bare = tag.replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: "\"\"", options: .regularExpression)
        let hidden = matches(bare, #"(?i)\shidden(\s|=|/|>)"#) || matches(style, #"(?:^|;)\s*(display\s*:\s*none|visibility\s*:\s*hidden)"#)
        if tiny || (hidden && !dims.contains { !($0 <= 2) }) { return true }
        let target = (url.host ?? "").lowercased() + url.percentEncodedPath
        return images.contains { matches(target, $0) }
    }
}
