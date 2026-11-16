import ClewDomain
import Foundation

/// Today and Goals & Later (SPEC 2026-11-15): moving items between the two lists, for
/// today only, and each list's own order. Moved to Today is a live `Plan` for today
/// with its place in Today's order; nothing else on the item changes, so the next day,
/// with no plan, it is back in Goals & Later.
public enum ListPlace: Sendable, Equatable { case today, goalsAndLater }

extension Clew {
    /// Puts the item in `list` between two neighbours of that list (either may be nil
    /// at its ends): reorders within a list, or moves across. Moving to Today is for
    /// today only; moving down undoes a move to Today, or sends an unticked once task or
    /// link to Later. Habits stay on Today.
    public func place(itemId: UUID, in list: ListPlace, after above: UUID?, before below: UUID?) throws {
        let now = clockForQueries.now()
        let day = currentDay()
        try storeForQueries.write { w in
            try place(itemId: itemId, in: list, after: above, before: below, day: day, now: now, w)
        }
    }

    /// Right-click › Move to Today: at Today's end.
    public func moveToToday(itemId: UUID) throws {
        let now = clockForQueries.now()
        let day = currentDay()
        try storeForQueries.write { w in
            let last = try todayList(w, on: day).rows.last?.id
            try place(itemId: itemId, in: .today, after: last == itemId ? nil : last, before: nil, day: day, now: now, w)
        }
    }

    /// Right-click › Move to Goals & Later: undoes today's move, back at its old place.
    public func moveBack(itemId: UUID) throws {
        let now = clockForQueries.now()
        let day = currentDay()
        try storeForQueries.write { w in
            guard try todayList(w, on: day).moved.contains(itemId) else { throw ClewError.notAllowed }
            try voidPlans(of: itemId, on: day, now: now, w)
            try releaseBlocksLeftToday(today: day, now: now, w)
        }
    }

    // MARK: - Inside one write

    func place(itemId: UUID, in list: ListPlace, after above: UUID?, before below: UUID?,
               day: LocalDay, now: Date, _ w: any StoreWriter) throws {
        guard var item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
        let current = try todayList(w, on: day)
        let moved = try Self.moved(w, on: day)
        let inToday = current.rows.contains { $0.id == itemId }
        let inBelow = current.goalsAndLater.contains { $0.id == itemId }
        guard inToday || inBelow else { throw ClewError.notAllowed }
        // What may cross: a Goals & Later row up; a moved row back down; a once task or
        // link of Today's own with no tick, down to Later. Habits stay.
        let crossing = (list == .today) != inToday
        if crossing, list == .goalsAndLater, !current.moved.contains(itemId) {
            guard item.kind == .once || item.kind == .link, item.state == .active,
                  (try w.progressAmounts(itemIds: [itemId])[itemId] ?? 0) == 0
            else { throw ClewError.notAllowed }
        }
        if crossing, list == .today, let row = current.goalsAndLater.first(where: { $0.id == itemId }),
           row.isGoalReached {
            throw ClewError.notAllowed      // a reached goal waits for Next round or a higher target
        }
        let key = try newKey(in: list, after: above, before: below, excluding: itemId, day: day, now: now, w)
        switch list {
        case .today:
            if inToday, !current.moved.contains(itemId) {
                item.sortKey = key                 // one of Today's own
                item.updatedAt = now
                try w.update(item)
            } else {
                // Moved here (or moving up now): its place is its plan's.
                if moved[itemId] != nil { try voidPlans(of: itemId, on: day, now: now, w) }
                try w.insert(Plan(id: newID(), itemId: itemId, localDay: day, at: now, source: .user, todaySortKey: key))
            }
        case .goalsAndLater:
            if current.moved.contains(itemId) { try voidPlans(of: itemId, on: day, now: now, w) }
            if crossing, item.state == .active, item.kind == .once || item.kind == .link {
                item.state = .later                // Today's own once task or link, to Later
                item.plannedDay = nil
            }
            item.sortKey = key
            item.updatedAt = now
            try w.update(item)
            if crossing { try releaseBlocksLeftToday(today: day, now: now, w) }
        }
    }

    /// A key between the neighbours' places in `list` (Today's places are a moved row's
    /// plan key, else the item's sort key). At an end: one past the neighbour; an empty
    /// list: past everything. Out of room: the list is renumbered first.
    private func newKey(in list: ListPlace, after above: UUID?, before below: UUID?, excluding id: UUID,
                        day: LocalDay, now: Date, _ w: any StoreWriter) throws -> Double {
        func keys() throws -> [UUID: Double] {
            let current = try todayList(w, on: day)
            let moved = try Self.moved(w, on: day)
            let rows = list == .today ? current.rows : current.goalsAndLater
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row.id, list == .today ? ((moved[row.id] ?? nil) ?? row.item.sortKey) : row.item.sortKey)
            })
        }
        var places = try keys()
        func key(_ neighbour: UUID?) throws -> Double? {
            guard let neighbour else { return nil }
            guard neighbour != id, let k = places[neighbour] else { throw ClewError.notAllowed }
            return k
        }
        switch (try key(above), try key(below)) {
        case let (low?, high?):
            guard low < high else { throw ClewError.notAllowed }
            let middle = (low + high) / 2
            if low < middle, middle < high { return middle }
            // Out of floating-point room (about 50 moves into one gap): renumber.
            try renumber(list, day: day, now: now, w)
            places = try keys()
            return places[above!]! + 0.5
        case let (low?, nil): return low + 1
        case let (nil, high?): return high - 1
        case (nil, nil): return (try w.maxSortKey() ?? 0) + 1
        }
    }

    /// Gives every row of `list` the place 1, 2, 3… in its current order: an item's own
    /// sort key, or for a moved row a fresh plan (plans are facts: void and insert).
    private func renumber(_ list: ListPlace, day: LocalDay, now: Date, _ w: any StoreWriter) throws {
        let current = try todayList(w, on: day)
        let rows = list == .today ? current.rows : current.goalsAndLater
        for (index, row) in rows.enumerated() {
            let key = Double(index + 1)
            if list == .today, current.moved.contains(row.id) {
                try voidPlans(of: row.id, on: day, now: now, w)
                try w.insert(Plan(id: newID(), itemId: row.id, localDay: day, at: now, source: .user, todaySortKey: key))
            } else if var item = try w.item(id: row.id), item.sortKey != key {
                item.sortKey = key
                item.updatedAt = now
                try w.update(item)
            }
        }
    }

    func voidPlans(of itemId: UUID, on day: LocalDay, now: Date, _ w: any StoreWriter) throws {
        for plan in try w.plans(on: day) where plan.itemId == itemId {
            try w.voidPlan(id: plan.id, at: now)
        }
    }
}
