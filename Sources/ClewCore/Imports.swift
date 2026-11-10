import ClewDomain
import Foundation

/// One entry of an external list (ARCHITECTURE §4.2 `ImportExternal`): its id on the
/// site and its title, as scraped. The URL is built here from the id, never taken
/// from the client.
public struct ExternalEntry: Hashable, Sendable, Codable {
    public var externalRef: String
    public var title: String
    /// How much was watched, 0–1, when the site shows it. Out-of-range values are
    /// ignored (the entry itself is still imported).
    public var progress: Double?

    public init(externalRef: String, title: String, progress: Double? = nil) {
        self.externalRef = externalRef
        self.title = title
        self.progress = progress
    }
}

/// What a scan of an external list saw. `listTotal` is the site's own count of the
/// list; only when it agrees with the entries is the scan treated as the whole list.
public struct ImportBatch: Hashable, Sendable {
    public var source: Source
    public var entries: [ExternalEntry]
    public var listTotal: Int?
    /// What the scraper saw on the page. Without it the batch is never the whole list.
    public var scan: ScanReport?
    /// For a list without a count (X bookmarks): how many leading entries the scraper
    /// saw as one unbroken run from the top of the list. Only that run is compared with
    /// the order Clew last saw (the gap rule, SPEC 2026-11-10).
    public var fromTop: Int?

    public init(source: Source, entries: [ExternalEntry], listTotal: Int?, scan: ScanReport? = nil, fromTop: Int? = nil) {
        self.source = source
        self.entries = entries
        self.listTotal = listTotal
        self.scan = scan
        self.fromTop = fromTop
    }
}

public struct ImportResult: Hashable, Sendable, Codable {
    /// New items in the source's collection.
    public var added: Int
    /// Titles brought up to date (only titles the user never edited).
    public var renamed: Int
    /// Items that had been let go because they left the list and are back on it.
    public var restored: Int
    /// Items that left the list (they leave it for its Done group; SPEC 2026-11-10).
    public var letGo: Int
    /// Entries skipped as malformed (bad id or empty title).
    public var skipped: Int
    /// Items whose watch progress changed.
    public var progressed: Int
    /// Whether the scan was the whole list (so removals could be applied).
    public var complete: Bool

    public init(added: Int = 0, renamed: Int = 0, restored: Int = 0, letGo: Int = 0, skipped: Int = 0,
                progressed: Int = 0, complete: Bool = false) {
        self.added = added
        self.renamed = renamed
        self.restored = restored
        self.letGo = letGo
        self.skipped = skipped
        self.progressed = progressed
        self.complete = complete
    }
}

extension Clew {
    /// Largest list a site offers (YouTube's Watch Later holds at most 5,000).
    public static let maxImportEntries = 5_000
    static let letGoBecauseGone = "left the external list"

    /// Idempotent import of an external list into its collection (ADR-4: the import
    /// path, not the agent). Keyed by `(source, externalRef)`, so re-scans never
    /// duplicate. New entries join the source's collection with a fetched (untrusted)
    /// title. When the scan is the whole list, items no longer on it leave the list and
    /// count as finished: one not ticked yet gets a tick dated the day the import saw
    /// it gone (SPEC decision 2026-11-10). One that comes back is restored. Items the
    /// user deleted stay gone. A list turned off in Settings imports nothing.
    @discardableResult
    public func importExternal(_ batch: ImportBatch) throws -> ImportResult {
        guard Self.importSources.contains(batch.source) else { throw ClewError.notAllowed }
        guard try !collectionsOff().contains(batch.source) else { throw ClewError.listTurnedOff }
        guard batch.entries.count <= Self.maxImportEntries else { throw ClewError.tooManyEntries(max: Self.maxImportEntries) }

        var result = ImportResult()
        var seen = Set<String>()
        var entries: [(ref: String, title: String, url: URL, progress: Double?)] = []
        for entry in batch.entries {
            guard let ref = Self.validExternalRef(entry.externalRef, source: batch.source),
                  let title = Self.importedTitle(entry.title),
                  let url = Self.externalURL(ref, source: batch.source)
            else { result.skipped += 1; continue }
            if seen.insert(ref).inserted { entries.append((ref, title, url, Self.watchFraction(entry.progress))) }
        }
        // The whole list only if the site's count, the rows on the page and the parsed
        // entries all agree, nothing was malformed, and the list is not empty: a broken
        // scraper must never cause removals. An empty read is never trusted, since "No
        // videos" also shows on a signed-out or failed page.
        let scanAgrees = batch.scan.map { $0.found == $0.parsed && $0.parsed == batch.entries.count } ?? false
        // A list without a count (X) is never whole: a stray number must not stand in for one.
        result.complete = !Self.orderedSources.contains(batch.source)
            && scanAgrees && !entries.isEmpty && batch.listTotal == entries.count && result.skipped == 0

        let now = clockForQueries.now()
        let zone = zonesForQueries.current()
        let day = currentDay()
        return try storeForQueries.write { w in
            var existing: [String: Item] = [:]
            for item in try w.items(source: batch.source) {
                if let ref = item.externalRef { existing[ref] = item }
            }
            var sortKey = try w.maxSortKey() ?? 0
            let watched = try w.watchProgress(itemIds: existing.values.map(\.id))
            /// Saves a new reading only when it differs from the stored one, so
            /// re-scans write nothing.
            func record(_ fraction: Double?, for itemId: UUID) throws {
                guard let fraction, watched[itemId]?.fraction != fraction else { return }
                try w.save(WatchProgress(itemId: itemId, fraction: fraction, observedAt: now, source: batch.source))
                result.progressed += 1
            }
            for entry in entries {
                if var item = existing[entry.ref] {
                    var changed = false
                    if item.deletedAt != nil {
                        // A scan may be stale (sent from another tab, or read just before
                        // a click), so it cannot undo a removal for a while; a click can.
                        guard try Self.restore(&item, source: batch.source, at: now,
                                               leftBefore: now.addingTimeInterval(-Self.restoreAfter), w)
                        else { continue }
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
                    try record(entry.progress, for: item.id)
                } else {
                    sortKey += 1
                    let item = Item(
                        id: newID(), kind: .link, title: entry.title, titleOrigin: .fetched, url: entry.url,
                        schedule: .unscheduled, progress: .none, state: .later, sortKey: sortKey,
                        source: batch.source, externalRef: entry.ref, createdAt: now, updatedAt: now
                    )
                    try w.insert(item)
                    result.added += 1
                    try record(entry.progress, for: item.id)
                }
            }

            // A list with a count: removals only from a scan of the whole list.
            if result.complete {
                let onList = Set(entries.map(\.ref))
                let gone = existing.values.filter { item in
                    item.deletedAt == nil && !onList.contains(item.externalRef ?? "")
                }
                result.letGo += try leaveList(gone, source: batch.source, now: now, day: day, zone: zone, w)
            }
            // A list with a count keeps the site's order for its page: what this scan
            // saw, then what it did not, as before.
            if !Self.orderedSources.contains(batch.source) {
                let live = Set(try w.items(source: batch.source).filter { $0.deletedAt == nil }.compactMap(\.externalRef))
                let seen = entries.map(\.ref).filter { live.contains($0) }
                let inScan = Set(seen)
                let rest = try Self.listOrder(batch.source, w).filter { live.contains($0) && !inScan.contains($0) }
                try Self.saveListOrder(seen + rest, batch.source, now: now, w)
            }
            // A list without a count (X bookmarks): the gap rule on the unbroken run.
            if Self.orderedSources.contains(batch.source) {
                let run = scanAgrees && result.skipped == 0 ? max(0, batch.fromTop ?? 0) : 0   // never trust the client's number
                let live = Dictionary(uniqueKeysWithValues: try w.items(source: batch.source)
                    .filter { $0.deletedAt == nil }.compactMap { i in i.externalRef.map { ($0, i) } })
                let top = entries.prefix(run).map(\.ref)
                let (order, gone) = Self.gapRule(previous: try Self.listOrder(batch.source, w).filter { live[$0] != nil },
                                                 top: top)
                result.letGo += try leaveList(gone.compactMap { live[$0] }, source: batch.source,
                                                   now: now, day: day, zone: zone, w)
                // A post deleted in Clew may still be on the page (in the run): it keeps
                // no place (Gemini review 2026-11-10).
                try Self.saveListOrder(order.filter { live[$0] != nil }, batch.source, now: now, w)
            }
            return result
        }
    }

    /// Items leave the list for the collection's Done group: removed means finished,
    /// whether or not progress was ever seen, so one not ticked yet gets a tick dated
    /// today (SPEC 2026-11-10). The user can say otherwise with "Not finished". The
    /// let-go carries the import's source, so it is not counted as the user's.
    func leaveList(_ items: [Item], source: Source, now: Date, day: LocalDay, zone: TimeZone,
                   _ w: any StoreWriter) throws -> Int {
        let allTime = LocalDay(year: 1, month: 1, day: 1)!
        let ticked = Set(try w.checkIns(itemIds: items.map(\.id), from: allTime).map(\.itemId))
        for var item in items {
            if !ticked.contains(item.id) {
                try w.insert(CheckIn(id: newID(), itemId: item.id, localDay: day, at: now,
                                     timeZoneId: zone.identifier, amount: 1, source: source))
            }
            try w.insert(LaterReview(id: newID(), itemId: item.id, decision: .letGo, at: now, localDay: day, source: source))
            item.deletedAt = now
            item.updatedAt = now
            try w.update(item)
            if var reminder = try w.reminders().first(where: { $0.itemId == item.id }) {
                reminder.deletedAt = now
                reminder.updatedAt = now
                try w.save(reminder)
            }
        }
        return items.count
    }

    /// Brings back an item that left the list and reappeared (for a scan, only if it left
    /// before `leftBefore`): its let-go is voided, and
    /// so are the ticks the import gave it, so it is to watch again; a tick the user made
    /// stays. False if the user removed it (it stays gone).
    static func restore(_ item: inout Item, source: Source, at now: Date, leftBefore: Date? = nil,
                        _ w: any StoreWriter) throws -> Bool {
        guard let review = try automaticLetGo(of: item, source: source, w) else { return false }
        if let leftBefore, review.at > leftBefore { return false }
        try w.voidLaterReview(id: review.id, at: now)
        let allTime = LocalDay(year: 1, month: 1, day: 1)!
        for tick in try w.checkIns(itemIds: [item.id], from: allTime) where tick.source == source {
            try w.voidCheckIn(id: tick.id, at: now, reason: "back on the list")
        }
        item.deletedAt = nil
        return true
    }

    static let importSources: Set<Source> = [.extensionYouTube, .extensionX]

    /// How long after leaving the list an item can be brought back by a scan. A scan
    /// can be stale: another tab still showing the post, or rows read just before an
    /// unbookmark click (seen 19 → 18 → 19, 2026-11-10). A bookmark click is never
    /// stale and restores at once.
    public static let restoreAfter: TimeInterval = 10 * 60

    /// Lists imported from a site, each shown as one collection below the tasks, in this
    /// order. Their items never appear on Today, in Later or in Pick.
    public static let collectionSources: [Source] = [.extensionYouTube, .extensionX]

    /// Lists with no count on the page, read as they scroll (X bookmarks, newest first):
    /// removals come from the gap rule and from the bookmark button, never from a
    /// whole-list compare.
    static let orderedSources: Set<Source> = [.extensionX]

    /// The gap rule (SPEC 2026-11-10). `previous` is the list as Clew last saw it, top
    /// first; `top` an unbroken run from the top of the list now. An item that was
    /// between two consecutive known items of the run, and is not in the run, was
    /// removed. Nothing below the run is decided.
    ///
    /// A post bookmarked again (on the phone, unseen) jumps to the top, so the list is a
    /// block of moved posts above the rest in its old order. Pairs inside the moved block
    /// prove nothing (Gemini review, 2026-11-10: re-bookmark E then C, and a run [C, E]
    /// would wrongly take D as gone). Only the part of the run after its last step
    /// backwards in the old order is trusted: once the run reaches the posts that never
    /// moved, every gap there is real. A run that lies wholly inside a moved block of
    /// two or more posts is the remaining blind spot ("Not read" undoes it). The top of
    /// the list counts as a bound when nothing in the run is out of order.
    /// Returns the new order (the run, then the rest as before) and the removed refs.
    public static func gapRule(previous: [String], top: [String]) -> (order: [String], removed: [String]) {
        let position = Dictionary(previous.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let inRun = Set(top)
        let known = top.compactMap { position[$0] }
        let lastStepBack = known.indices.dropLast().last { known[$0] > known[$0 + 1] }
        // The run starts at the top of the list, so with nothing out of order the top
        // itself is a bound too (-1): the newest bookmark, removed on the phone, is
        // caught even though it has nothing above it.
        let trusted = lastStepBack.map { Array(known[($0 + 1)...]) } ?? ([-1] + known)
        // `trusted` never steps back, so the ranges below do not overlap: each post is
        // removed at most once.
        var removed: [String] = []
        for (x, y) in zip(trusted, trusted.dropFirst()) where x < y {
            for i in (x + 1)..<y where !inRun.contains(previous[i]) { removed.append(previous[i]) }
        }
        let gone = Set(removed)
        var seen = Set<String>()
        let order = (top + previous.filter { !inRun.contains($0) && !gone.contains($0) }).filter { seen.insert($0).inserted }
        return (order, removed)
    }

    /// The order a list was last seen in, top first (derived state, kept in settings).
    /// Collection pages list what is left in this order (SPEC 2026-11-10).
    static func listOrder(_ source: Source, _ r: any StoreReader) throws -> [String] {
        guard let json = try r.setting(listOrderKey(source)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    static func saveListOrder(_ order: [String], _ source: Source, now: Date, _ w: any StoreWriter) throws {
        guard try listOrder(source, w) != order else { return }
        let json = String(decoding: try JSONEncoder().encode(order), as: UTF8.self)
        try w.saveSetting(listOrderKey(source), json: json, updatedAt: now)
    }

    static func listOrderKey(_ source: Source) -> String { "listOrder.\(source.rawValue)" }

    static func isCollectionItem(_ item: Item) -> Bool { collectionSources.contains(item.source) }

    /// The let-go that removed `item`, if the import made it (not the user).
    static func automaticLetGo(of item: Item, source: Source, _ r: any StoreReader) throws -> LaterReview? {
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
        case .extensionX:
            // A post id: 1–19 digits, no leading zero (it fits in a signed 64-bit integer).
            let digits = ref.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
            return digits && (1...19).contains(ref.unicodeScalars.count) && !ref.hasPrefix("0") && Int64(ref) != nil ? ref : nil
        default:
            return nil
        }
    }

    static func externalURL(_ ref: String, source: Source) -> URL? {
        switch source {
        case .extensionYouTube: URL(string: "https://www.youtube.com/watch?v=\(ref)")
        case .extensionX: URL(string: "https://x.com/i/status/\(ref)")
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
extension Clew {
    /// 0–1 rounded to 0.01, or nil when absent or out of range.
    static func watchFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return (value * 100).rounded() / 100
    }
}

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
