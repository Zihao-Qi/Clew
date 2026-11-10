import ClewDomain
import Foundation

extension Clew {
    /// The bookmark button was clicked on a post (X, in Chrome; SPEC decision
    /// 2026-11-10). Bookmarked: the post joins the collection at the top of its list, or
    /// comes back if it had left it (to read again). Unbookmarked: it leaves the list and
    /// counts as read, like a removal the import saw. A post the user deleted in Clew
    /// stays gone; one Clew never saw is ignored when unbookmarked.
    @discardableResult
    public func bookmarkChanged(source: Source, entry: ExternalEntry, bookmarked: Bool) throws -> ImportResult {
        guard Self.orderedSources.contains(source) else { throw ClewError.notAllowed }
        guard try !collectionsOff().contains(source) else { throw ClewError.listTurnedOff }
        var result = ImportResult()
        guard let ref = Self.validExternalRef(entry.externalRef, source: source),
              let url = Self.externalURL(ref, source: source)
        else { result.skipped = 1; return result }
        // An unbookmark needs no title; a bookmark without one is skipped.
        let title = Self.importedTitle(entry.title)
        if bookmarked && title == nil { result.skipped = 1; return result }

        let now = clockForQueries.now()
        let zone = zonesForQueries.current()
        let day = currentDay()
        return try storeForQueries.write { w in
            let existing = try w.items(source: source).first { $0.externalRef == ref }
            var order = try Self.listOrder(source, w).filter { $0 != ref }
            if bookmarked, let title {
                if var item = existing {
                    if item.deletedAt != nil {
                        guard try Self.restore(&item, source: source, at: now, w) else { return result }
                        item.updatedAt = now
                        try w.update(item)
                        result.restored = 1
                    }
                } else {
                    let item = Item(
                        id: newID(), kind: .link, title: title, titleOrigin: .fetched, url: url,
                        schedule: .unscheduled, progress: .none, state: .later, sortKey: (try w.maxSortKey() ?? 0) + 1,
                        source: source, externalRef: ref, createdAt: now, updatedAt: now
                    )
                    try w.insert(item)
                    result.added = 1
                }
                order.insert(ref, at: 0)   // a new bookmark is the newest
            } else if let item = existing, item.deletedAt == nil {
                result.letGo = try leaveList([item], source: source, now: now, day: day, zone: zone, w)
            }
            try Self.saveListOrder(order, source, now: now, w)
            return result
        }
    }
}
