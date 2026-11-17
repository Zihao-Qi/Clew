import ClewDomain
import Foundation

extension Item {
    /// The site shown beside a saved link's title in Goals & Later, e.g. "medium.com"
    /// (as Pick showed it until 2026-11-15). None for YouTube: those are videos, which
    /// the title already says (user, 2026-11-09).
    public var siteLabel: String? {
        guard kind == .link, let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let youTube = site == "youtube.com" || site.hasSuffix(".youtube.com") || site == "youtu.be"
        return youTube ? nil : site
    }
}
