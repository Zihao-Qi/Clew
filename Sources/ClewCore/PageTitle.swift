import Foundation

/// Finds a page's title in its HTML: `og:title`, then `twitter:title`, then
/// `<meta name="title">`, then `<title>`. The result is untrusted text written by a
/// stranger; it is only ever shown as a title, and recorded as `.fetched`.
public enum PageTitle {
    public static func extract(fromHTML html: String) -> String? {
        let metas = metaContents(html)
        let titleTag = groups(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).first?.first
        for candidate in [metas["og:title"], metas["twitter:title"], metas["title"], titleTag] {
            if let raw = candidate, let title = QuickEntry.cleanTitle(decodeEntities(raw)) {
                return title
            }
        }
        return nil
    }

    /// Whether a page read so far already holds a complete `<meta property="og:title">`
    /// with a usable value, so the fetcher can stop. `</head>` is no signal: YouTube
    /// playlist pages have one inside a script about 50 KB before their real title.
    public static func hasOpenGraphTitle(_ prefix: Data) -> Bool {
        guard prefix.range(of: Data("og:title".utf8)) != nil else { return false } // cheap pre-check
        let html = String(decoding: prefix, as: UTF8.self)
        return metaContents(html)["og:title"].flatMap { QuickEntry.cleanTitle(decodeEntities($0)) } != nil
    }

    /// `property`/`name` → `content` of every complete `<meta>` tag; the first wins.
    /// Quoted values may contain `>`.
    private static func metaContents(_ html: String) -> [String: String] {
        var metas: [String: String] = [:]
        for tag in matches(#"<meta\s(?:[^>"']|"[^"]*"|'[^']*')*>"#, in: html) {
            var attributes: [String: String] = [:]
            for pair in groups(#"([a-zA-Z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag) {
                attributes[pair[0].lowercased()] = pair[1].isEmpty ? pair[2] : pair[1]
            }
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"], metas[key] == nil
            else { continue }
            metas[key] = content
        }
        return metas
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    decoded = named[name]
                }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Capture groups of each match; a group that did not participate is "".
    private static func groups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { i in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
