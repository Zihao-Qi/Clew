import Foundation

/// How much got done (SPEC 2026-11-18, "Done so far"): each item that is not from a
/// collection counts **once on each Clew day it has a live tick** — a once task or link
/// the day it is ticked, a habit each day it is done, a goal each day it got any +1
/// (40 pages read is 1). Last week's card and the Done so far line both count this way.
public enum DoneCount {
    public static let collectionSources: Set<Source> = [.extensionYouTube, .extensionX]

    /// Items done on each day: live ticks only, collection items left out, items
    /// deleted since still counted (history is kept).
    public static func byDay(_ ticks: [(checkIn: CheckIn, item: Item)]) -> [LocalDay: Int] {
        var seen = Set<String>()
        var counts: [LocalDay: Int] = [:]
        for tick in ticks where !tick.checkIn.isVoided && !collectionSources.contains(tick.item.source) {
            guard seen.insert("\(tick.item.id)|\(tick.checkIn.localDay)").inserted else { continue }
            counts[tick.checkIn.localDay, default: 0] += 1
        }
        return counts
    }
}
