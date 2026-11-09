import Foundation

/// Interprets what was typed or pasted into `+ add`: an optional title and at most
/// one web link, in any order ("ML course https://…", or a bare link).
public enum QuickEntry {
    public struct Parsed: Equatable, Sendable {
        public let title: String
        public let url: URL?
        /// True when the text was only a link. SPEC: a pasted link goes to Later.
        public let isBareLink: Bool

        public init(title: String, url: URL?, isBareLink: Bool) {
            self.title = title
            self.url = url
            self.isBareLink = isBareLink
        }
    }

    public static func parse(_ text: String) -> Parsed {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let index = words.firstIndex(where: { webURL($0) != nil }), let url = webURL(words[index]) else {
            return Parsed(title: words.joined(separator: " "), url: nil, isBareLink: false)
        }
        var rest = words
        rest.remove(at: index)
        let title = rest.joined(separator: " ")
        if title.isEmpty {
            return Parsed(title: fallbackTitle(for: url), url: url, isBareLink: true)
        }
        return Parsed(title: title, url: url, isBareLink: false)
    }

    /// A title fetched from a web page, made fit for a row: whitespace collapsed,
    /// capped at `Clew.maxTitleLength`. Nil if nothing is left.
    public static func cleanTitle(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let title = words.joined(separator: " ")
        return title.count > Clew.maxTitleLength ? String(title.prefix(Clew.maxTitleLength - 1)) + "…" : title
    }

    static func webURL(_ word: String) -> URL? {
        guard let url = URL(string: word), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// "youtube.com/watch?v=…" from "https://www.youtube.com/watch?v=…", capped so it
    /// fits in a row. Clew has no network access, so it cannot fetch the page title.
    static func fallbackTitle(for url: URL) -> String {
        var host = url.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        if let query = url.query { path += "?" + query }
        if path == "/" { path = "" }
        let full = host + path
        return full.count > 80 ? String(full.prefix(79)) + "…" : full
    }
}
