import ClewDomain
import Foundation

/// A list imported from a site (YouTube Watch Later, later X bookmarks), shown as one
/// row below the tasks (SPEC decision 2026-11-09). It is not a task: no circle, not
/// counted in today's done/total.
public struct CollectionSummary: Hashable, Sendable, Identifiable {
    public let source: Source
    /// Items on the list now.
    public let total: Int
    /// Of those, the ones ticked.
    public let done: Int

    public var id: Source { source }
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
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

    public var id: UUID { item.id }
}

/// Everything a collection's page shows.
public struct CollectionDetails: Hashable, Sendable {
    public let source: Source
    public let today: LocalDay
    /// Started, not ticked: most watched first.
    public let inProgress: [CollectionEntry]
    /// Not started, not ticked: newest first.
    public let notStarted: [CollectionEntry]
    /// Ticked: most recent first.
    public let done: [CollectionEntry]
    /// Items ticked per day, all time, including items since removed from the list: the
    /// heatmap keeps what got done.
    public let finishedByDay: [LocalDay: Int]
    public let finishedThisWeek: Int
    public let finishedLast30: Int
    public let finishedAllTime: Int

    public var total: Int { inProgress.count + notStarted.count + done.count }
}

extension Clew {
    /// The collections that have something on them, in `collectionSources` order.
    public func collections() throws -> [CollectionSummary] {
        try storeForQueries.read { r in
            try Self.collectionSources.compactMap { source in
                let live = try r.items(source: source).filter { $0.deletedAt == nil }
                guard !live.isEmpty else { return nil }
                let ticked = try r.progressAmounts(itemIds: live.map(\.id)).filter { $0.value > 0 }.count
                return CollectionSummary(source: source, total: live.count, done: ticked)
            }
        }
    }

    public func collection(_ source: Source) throws -> CollectionDetails? {
        guard Self.collectionSources.contains(source) else { return nil }
        let today = currentDay()
        return try storeForQueries.read { r in
            let all = try r.items(source: source)
            let allTime = LocalDay(year: 1, month: 1, day: 1)!
            let ticks = try r.checkIns(itemIds: all.map(\.id), from: allTime).filter { $0.localDay <= today }
            let lastTick = Dictionary(grouping: ticks, by: \.itemId).mapValues { $0.max { $0.at < $1.at }! }
            let live = all.filter { $0.deletedAt == nil }
            let watched = try r.watchProgress(itemIds: live.map(\.id))

            var inProgress: [CollectionEntry] = [], notStarted: [CollectionEntry] = [], done: [CollectionEntry] = []
            for item in live {
                let tick = lastTick[item.id]
                let entry = CollectionEntry(item: item, watched: watched[item.id]?.fraction, doneAt: tick?.at,
                                            doneToday: tick?.localDay == today)
                if tick != nil { done.append(entry) }
                else if (entry.watched ?? 0) > 0 { inProgress.append(entry) }
                else { notStarted.append(entry) }
            }
            let newestFirst = { (a: CollectionEntry, b: CollectionEntry) in
                (a.item.createdAt, a.item.id.uuidString) > (b.item.createdAt, b.item.id.uuidString)
            }
            inProgress.sort { ($0.watched ?? 0, $0.item.createdAt) > ($1.watched ?? 0, $1.item.createdAt) }
            notStarted.sort(by: newestFirst)
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
}
