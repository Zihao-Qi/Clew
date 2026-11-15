import Foundation

/// Last week's card (SPEC 2026-11-15): what got done in one Monday-to-Sunday week,
/// never a comparison or anything missed. Pure: Core passes the week's live ticks with
/// their items, the live focus sessions, and the deletion facts.
public struct WeekRecap: Equatable, Sendable {
    public struct Highlight: Equatable, Sendable {
        public let itemId: UUID
        public let title: String
        public let count: Int
    }

    /// The week's Monday.
    public let weekStart: LocalDay
    /// Tick amounts on items that are not from a collection (a goal's +1 is one).
    public let done: Int
    public let focusMinutes: Int
    /// Distinct YouTube / X items ticked that week; nil when that list is turned off.
    public let watched: Int?
    public let read: Int?
    /// Habits and goals ticked at least twice, most first, at most two.
    public let highlights: [Highlight]

    public static let maxHighlights = 2
    public static let collectionSources: Set<Source> = [.extensionYouTube, .extensionX]

    public init(weekStart: LocalDay, done: Int, focusMinutes: Int, watched: Int?, read: Int?, highlights: [Highlight]) {
        self.weekStart = weekStart; self.done = done; self.focusMinutes = focusMinutes
        self.watched = watched; self.read = read; self.highlights = highlights
    }

    /// The recap of the week starting `weekStart`, or nil when nothing would show
    /// (done, watched and read all 0; focus time alone does not count).
    /// - ticks: live check-ins with their items (deleted items included).
    /// - userDeleted: items the user deleted (not ones that left a site's list).
    public static func make(weekStart: LocalDay, ticks: [(checkIn: CheckIn, item: Item)],
                            focus: [FocusSession], userDeleted: Set<UUID>,
                            listsOff: Set<Source>) -> WeekRecap? {
        let end = weekStart.adding(days: 6)
        let inWeek = ticks.filter { $0.checkIn.localDay >= weekStart && $0.checkIn.localDay <= end && !$0.checkIn.isVoided }
        let done = inWeek.filter { !collectionSources.contains($0.item.source) }.reduce(0) { $0 + $1.checkIn.amount }
        func collection(_ source: Source) -> Int? {
            guard !listsOff.contains(source) else { return nil }
            return Set(inWeek.filter { $0.item.source == source && !userDeleted.contains($0.item.id) }.map(\.item.id)).count
        }
        let watched = collection(.extensionYouTube)
        let read = collection(.extensionX)
        guard done > 0 || (watched ?? 0) > 0 || (read ?? 0) > 0 else { return nil }
        let focusMinutes = focus.filter { $0.localDay >= weekStart && $0.localDay <= end && $0.voidedAt == nil }
            .reduce(0) { $0 + $1.minutes }
        var counts: [UUID: (item: Item, count: Int)] = [:]
        for tick in inWeek where (tick.item.kind == .habit || tick.item.kind == .goal)
            && tick.item.deletedAt == nil && !collectionSources.contains(tick.item.source) {
            counts[tick.item.id, default: (tick.item, 0)].count += tick.checkIn.amount
        }
        let highlights = counts.values.filter { $0.count >= 2 }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                // The list's own order: sort key, then created, then id (as Today).
                if a.item.sortKey != b.item.sortKey { return a.item.sortKey < b.item.sortKey }
                if a.item.createdAt != b.item.createdAt { return a.item.createdAt < b.item.createdAt }
                return a.item.id.uuidString < b.item.id.uuidString
            }
            .prefix(maxHighlights)
            .map { Highlight(itemId: $0.item.id, title: $0.item.title, count: $0.count) }
        return WeekRecap(weekStart: weekStart, done: done, focusMinutes: focusMinutes,
                         watched: watched, read: read, highlights: Array(highlights))
    }
}
