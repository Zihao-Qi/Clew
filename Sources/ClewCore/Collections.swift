import ClewDomain
import Foundation

/// A list imported from a site (YouTube Watch Later, later X bookmarks), shown as one
/// row below the tasks (SPEC decision 2026-11-09). It is not a task: no circle, not
/// counted in today's done/total.
public struct CollectionSummary: Hashable, Sendable, Identifiable {
    public let source: Source
    /// On the list and not ticked: what is left to watch or read.
    public let toWatch: Int
    /// The Done group: ticked, including items since removed from the list (removed
    /// means finished, SPEC decision 2026-11-10).
    public let done: Int
    /// On the site's list now, ticked or not.
    public let onList: Int

    public var id: Source { source }
    /// Done out of everything the collection holds.
    public var fraction: Double { toWatch + done == 0 ? 0 : Double(done) / Double(toWatch + done) }
}

/// One video or post on a collection's page.
public struct CollectionEntry: Hashable, Sendable, Identifiable {
    public let item: Item
    /// How much of the video was watched (0–1), if seen.
    public let watched: Double?
    /// When it was ticked (its latest live tick), if it was.
    public let doneAt: Date?
    /// Ticked today, so the circle can undo it.
    public let doneToday: Bool
    /// Still on the site's list. One that left it sits in Done and can be marked
    /// "Not finished" instead.
    public let onList: Bool

    public var id: UUID { item.id }
}

/// Everything a collection's page shows.
public struct CollectionDetails: Hashable, Sendable {
    public let source: Source
    public let today: LocalDay
    /// Started, not ticked: most watched first.
    public let inProgress: [CollectionEntry]
    /// Not started, not ticked: in the site's order.
    public let notStarted: [CollectionEntry]
    /// Ticked: most recent first.
    public let done: [CollectionEntry]
    /// Items ticked per day, all time, including items that left the list (they are in
    /// Done); never items the user deleted.
    public let finishedByDay: [LocalDay: Int]
    public let finishedThisWeek: Int
    public let finishedLast30: Int
    public let finishedAllTime: Int

    public var toWatch: Int { inProgress.count + notStarted.count }
    public var total: Int { toWatch + done.count }
}

extension Clew {
    /// The collections that are turned on and have something in them, or something
    /// finished in the past (so an emptied list keeps its heatmap reachable), in
    /// `collectionSources` order.
    public func collections() throws -> [CollectionSummary] {
        let off = try collectionsOff()
        return try storeForQueries.read { r in
            try Self.collectionSources.filter { !off.contains($0) }.compactMap { source in
                let all = try r.items(source: source)
                let allTime = LocalDay(year: 1, month: 1, day: 1)!
                let left = try Self.leftTheList(all, source: source, r)
                // What the user deleted is gone from the collection, its ticks too.
                let kept = all.filter { $0.deletedAt == nil || left.contains($0.id) }
                let ticks = try r.checkIns(itemIds: kept.map(\.id), from: allTime)
                let live = all.filter { $0.deletedAt == nil }
                guard !live.isEmpty || !ticks.isEmpty else { return nil }
                let ticked = Set(ticks.map(\.itemId))
                let done = kept.filter { ticked.contains($0.id) }.count
                return CollectionSummary(source: source, toWatch: live.filter { !ticked.contains($0.id) }.count,
                                         done: done, onList: live.count)
            }
        }
    }

    public func collection(_ source: Source) throws -> CollectionDetails? {
        guard Self.collectionSources.contains(source) else { return nil }
        let today = currentDay()
        return try storeForQueries.read { r in
            let left = try Self.leftTheList(try r.items(source: source), source: source, r)
            // What the user deleted is gone from the page, heatmap and counts included
            // (user, 2026-11-10: a deleted article still coloured the heatmap).
            let all = try r.items(source: source).filter { $0.deletedAt == nil || left.contains($0.id) }
            let allTime = LocalDay(year: 1, month: 1, day: 1)!
            let allTicks = try r.checkIns(itemIds: all.map(\.id), from: allTime)
            // Done-ness uses every live tick, as the row's count and CheckIn do, even one
            // dated after today (e.g. the clock or time zone moved back); the heatmap and
            // counts below only show days up to today.
            let lastTick = Dictionary(grouping: allTicks, by: \.itemId).mapValues { $0.max { $0.at < $1.at }! }
            let ticks = allTicks.filter { $0.localDay <= today }
            let watched = try r.watchProgress(itemIds: all.map(\.id))

            var inProgress: [CollectionEntry] = [], notStarted: [CollectionEntry] = [], done: [CollectionEntry] = []
            for item in all {
                let tick = lastTick[item.id]
                // Removed by the import and marked "Not finished": gone from the page.
                if item.deletedAt != nil && tick == nil { continue }
                let entry = CollectionEntry(item: item, watched: watched[item.id]?.fraction, doneAt: tick?.at,
                                            doneToday: tick?.localDay == today, onList: item.deletedAt == nil)
                if tick != nil { done.append(entry) }
                else if (entry.watched ?? 0) > 0 { inProgress.append(entry) }
                else { notStarted.append(entry) }
            }
            // What is left follows the site's own order (Watch Later's, X's newest bookmark
            // first); anything not placed yet goes last, newest first.
            let rank = Dictionary(try Self.listOrder(source, r).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let siteOrder = { (a: CollectionEntry, b: CollectionEntry) in
                let ra = rank[a.item.externalRef ?? ""] ?? Int.max, rb = rank[b.item.externalRef ?? ""] ?? Int.max
                if ra != rb { return ra < rb }
                return (a.item.createdAt, a.item.id.uuidString) > (b.item.createdAt, b.item.id.uuidString)
            }
            inProgress.sort {
                ($0.watched ?? 0, $0.item.createdAt, $0.item.id.uuidString) > ($1.watched ?? 0, $1.item.createdAt, $1.item.id.uuidString)
            }
            notStarted.sort(by: siteOrder)
            done.sort { ($0.doneAt ?? .distantPast, $0.item.id.uuidString) > ($1.doneAt ?? .distantPast, $1.item.id.uuidString) }

            var byDay: [LocalDay: Int] = [:]
            for tick in ticks { byDay[tick.localDay, default: 0] += 1 }
            return CollectionDetails(
                source: source, today: today, inProgress: inProgress, notStarted: notStarted, done: done,
                finishedByDay: byDay,
                finishedThisWeek: ticks.filter { $0.localDay.isInSameWeek(as: today) }.count,
                finishedLast30: ticks.filter { $0.localDay > today.adding(days: -30) }.count,
                finishedAllTime: ticks.count
            )
        }
    }

    /// "Not finished" on an item that left the list: its ticks are voided, so it leaves
    /// the Done group and the heatmap (SPEC decision 2026-11-10). Items still on the
    /// list are refused; their circle undoes today's tick as usual.
    public func markNotFinished(itemId: UUID) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard let item = try w.item(id: itemId) else { throw ClewError.itemNotFound }
            guard Self.isCollectionItem(item),
                  try Self.leftTheList([item], source: item.source, w).contains(item.id)
            else { throw ClewError.notAllowed }
            let allTime = LocalDay(year: 1, month: 1, day: 1)!
            for tick in try w.checkIns(itemIds: [itemId], from: allTime) {
                try w.voidCheckIn(id: tick.id, at: now, reason: "not finished")
            }
        }
    }

    /// Of `items`, the ones removed because they left the site's list (the import's
    /// own let-go is their latest), not deleted by the user.
    static func leftTheList(_ items: [Item], source: Source, _ r: any StoreReader) throws -> Set<UUID> {
        let removed = items.filter { $0.deletedAt != nil }
        guard !removed.isEmpty else { return [] }
        let latest = Dictionary(grouping: try r.laterReviews(itemIds: removed.map(\.id)).filter { $0.decision == .letGo },
                                by: \.itemId)
            .compactMapValues { $0.max { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) } }
        return Set(removed.filter { latest[$0.id]?.source == source }.map(\.id))
    }

    // MARK: On and off (Settings › General)

    static let collectionsOffKey = "collectionsOff"

    /// The lists the user turned off: hidden from the menu, and their imports refused.
    /// What they hold stays.
    public func collectionsOff() throws -> Set<Source> {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.collectionsOffKey) else { return [] }
            // Unknown sources (e.g. from a newer version) are dropped.
            let raw = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            return Set(raw.compactMap(Source.init(rawValue:)))
        }
    }

    public func setCollection(_ source: Source, on: Bool) throws {
        guard Self.collectionSources.contains(source) else { throw ClewError.notAllowed }
        var off = try collectionsOff()
        if on { off.remove(source) } else { off.insert(source) }
        let now = clockForQueries.now()
        let json = String(decoding: try JSONEncoder().encode(off.map(\.rawValue).sorted()), as: UTF8.self)
        try storeForQueries.write { try $0.saveSetting(Self.collectionsOffKey, json: json, updatedAt: now) }
    }
}
