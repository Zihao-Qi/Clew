import ClewDomain
import Foundation

/// One entry of an external list (ARCHITECTURE §4.2 `ImportExternal`): its id on the
/// site and its title, as scraped. The URL is built here from the id, never taken
/// from the client.
public struct ExternalEntry: Hashable, Sendable, Codable {
    public var externalRef: String
    public var title: String

    public init(externalRef: String, title: String) {
        self.externalRef = externalRef
        self.title = title
    }
}

/// What a scan of an external list saw. `listTotal` is the site's own count of the
/// list; only when it agrees with the entries is the scan treated as the whole list.
public struct ImportBatch: Hashable, Sendable {
    public var source: Source
    public var entries: [ExternalEntry]
    public var listTotal: Int?

    public init(source: Source, entries: [ExternalEntry], listTotal: Int?) {
        self.source = source
        self.entries = entries
        self.listTotal = listTotal
    }
}

public struct ImportResult: Hashable, Sendable, Codable {
    /// New items in the Later pile.
    public var added: Int
    /// Titles brought up to date (only titles the user never edited).
    public var renamed: Int
    /// Items that had been let go because they left the list and are back on it.
    public var restored: Int
    /// Untouched Later items that are no longer on the list, let go.
    public var letGo: Int
    /// Entries skipped as malformed (bad id or empty title).
    public var skipped: Int
    /// Whether the scan was the whole list (so removals could be applied).
    public var complete: Bool

    public init(added: Int = 0, renamed: Int = 0, restored: Int = 0, letGo: Int = 0, skipped: Int = 0,
                complete: Bool = false) {
        self.added = added
        self.renamed = renamed
        self.restored = restored
        self.letGo = letGo
        self.skipped = skipped
        self.complete = complete
    }
}

extension Clew {
    /// Largest list a site offers (YouTube's Watch Later holds at most 5,000).
    public static let maxImportEntries = 5_000
    static let letGoBecauseGone = "left the external list"

    /// Idempotent import of an external list into the Later pile (ADR-4: the import
    /// path, not the agent). Keyed by `(source, externalRef)`, so re-scans never
    /// duplicate. New entries become saved links in Later with a fetched (untrusted)
    /// title. When the scan is the whole list, Later items from this source that are
    /// no longer on it and never done are let go (SPEC decision
    /// 2026-11-09); one that comes back is restored. Items the user deleted or let go
    /// themselves stay gone, and nothing on Today or done is ever touched.
    @discardableResult
    public func importExternal(_ batch: ImportBatch) throws -> ImportResult {
        guard Self.importSources.contains(batch.source) else { throw ClewError.notAllowed }
        guard batch.entries.count <= Self.maxImportEntries else { throw ClewError.tooManyEntries(max: Self.maxImportEntries) }

        var result = ImportResult()
        var seen = Set<String>()
        var entries: [(ref: String, title: String, url: URL)] = []
        for entry in batch.entries {
            guard let ref = Self.validExternalRef(entry.externalRef, source: batch.source),
                  let title = Self.importedTitle(entry.title),
                  let url = Self.externalURL(ref, source: batch.source)
            else { result.skipped += 1; continue }
            if seen.insert(ref).inserted { entries.append((ref, title, url)) }
        }
        // The whole list only if the site's count and the parsed entries agree, and
        // nothing was malformed: a broken scraper must never cause removals.
        result.complete = batch.listTotal == entries.count && result.skipped == 0

        let now = clockForQueries.now()
        let day = currentDay()
        return try storeForQueries.write { w in
            var existing: [String: Item] = [:]
            for item in try w.items(source: batch.source) {
                if let ref = item.externalRef { existing[ref] = item }
            }
            var sortKey = try w.maxSortKey() ?? 0
            for entry in entries {
                if var item = existing[entry.ref] {
                    var changed = false
                    if item.deletedAt != nil {
                        guard let review = try Self.automaticLetGo(of: item, source: batch.source, w) else { continue }
                        try w.voidLaterReview(id: review.id, at: now)
                        item.deletedAt = nil   // only Later items are let go, so it is back in Later
                        changed = true
                        result.restored += 1
                    }
                    if item.titleOrigin == .fetched, item.title != entry.title {
                        item.title = entry.title
                        changed = true
                        result.renamed += 1
                    }
                    if changed {
                        item.updatedAt = now
                        try w.update(item)
                    }
                } else {
                    sortKey += 1
                    try w.insert(Item(
                        id: newID(), kind: .link, title: entry.title, titleOrigin: .fetched, url: entry.url,
                        schedule: .unscheduled, progress: .none, state: .later, sortKey: sortKey,
                        source: batch.source, externalRef: entry.ref, createdAt: now, updatedAt: now
                    ))
                    result.added += 1
                }
            }

            guard result.complete else { return result }
            let onList = Set(entries.map(\.ref))
            let gone = existing.values.filter { item in
                item.deletedAt == nil && item.state == .later && !onList.contains(item.externalRef ?? "")
            }
            let done = try w.progressAmounts(itemIds: gone.map(\.id))
            for var item in gone where (done[item.id] ?? 0) == 0 {
                try w.insert(LaterReview(id: newID(), itemId: item.id, decision: .letGo, at: now, localDay: day,
                                         source: batch.source))
                item.deletedAt = now
                item.updatedAt = now
                try w.update(item)
                if var reminder = try w.reminders().first(where: { $0.itemId == item.id }) {
                    reminder.deletedAt = now
                    reminder.updatedAt = now
                    try w.save(reminder)
                }
                result.letGo += 1
            }
            return result
        }
    }

    static let importSources: Set<Source> = [.extensionYouTube]

    /// The let-go that removed `item`, if the import made it (not the user).
    private static func automaticLetGo(of item: Item, source: Source, _ r: any StoreReader) throws -> LaterReview? {
        let latest = try r.laterReviews(itemIds: [item.id])
            .filter { $0.decision == .letGo }
            .max { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
        guard let latest, latest.source == source else { return nil }
        return latest
    }

    /// A YouTube video id: exactly 11 of `A–Z a–z 0–9 _ -`.
    static func validExternalRef(_ ref: String, source: Source) -> String? {
        switch source {
        case .extensionYouTube:
            let allowed = ref.unicodeScalars.allSatisfy {
                ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
            }
            return ref.unicodeScalars.count == 11 && allowed ? ref : nil
        default:
            return nil
        }
    }

    static func externalURL(_ ref: String, source: Source) -> URL? {
        switch source {
        case .extensionYouTube: URL(string: "https://www.youtube.com/watch?v=\(ref)")
        default: nil
        }
    }

    /// Whitespace collapsed to single spaces, control characters dropped, cut to the
    /// title limit. Nil if nothing is left.
    static func importedTitle(_ raw: String) -> String? {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) ? " " : $0
        }))
        let words = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return nil }
        let title = words.joined(separator: " ")
        guard title.count > maxTitleLength else { return title }
        return String(title.prefix(maxTitleLength - 1)) + "…"
    }
}

/// What a scraper saw on the page, sent with every scan (ARCHITECTURE §6 "health
/// report, not silence"): rows it found, rows it could read, and its selector table's
/// version.
public struct ScanReport: Hashable, Sendable, Codable {
    public var found: Int
    public var parsed: Int
    public var selectorVersion: String

    public init(found: Int, parsed: Int, selectorVersion: String) {
        self.found = found
        self.parsed = parsed
        self.selectorVersion = selectorVersion
    }

    /// The page changed under the scraper: rows it could not read, entries Clew had to
    /// skip, or a list whose own count says it has items while nothing was read.
    public func needsUpdate(listTotal: Int?, result: ImportResult) -> Bool {
        parsed < found || result.skipped > 0 || ((listTotal ?? 0) > 0 && parsed == 0)
    }
}
