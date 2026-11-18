import ClewDomain
import Foundation

/// A day for Later (SPEC 2026-11-17): a once task or link waits in Goals & Later for a
/// day, then is on Today for that day, as if moved there by hand that morning. The day
/// is a `Plan` recorded now for that future day, with no Today place; nothing else on
/// the item says so.

/// How a waiting row shows its day: "Tomorrow", a weekday for two to six days on,
/// otherwise the date.
public enum DayLabel: Hashable, Sendable {
    case tomorrow
    case weekday(LocalDay)
    case date(LocalDay)

    public init(_ day: LocalDay, today: LocalDay) {
        switch day.ordinal - today.ordinal {
        case ...1: self = .tomorrow
        case 2...6: self = .weekday(day)
        default: self = .date(day)
        }
    }
}

extension Clew {
    /// Right-click › Later until › Next Monday: the Monday that starts the next Clew week.
    public static func nextMonday(after today: LocalDay) -> LocalDay { today.weekStart.adding(days: 7) }

    /// Whether `row` can be given a day: a once task or link with no tick, on Today or
    /// in Goals & Later (not a habit, a goal or a collection's item).
    public static func canHaveDay(_ row: TodayRow) -> Bool {
        (row.item.kind == .once || row.item.kind == .link) && row.progressAmount == 0 && row.todayAmount == 0
            && !isCollectionItem(row.item)
    }

    /// The day each Goals & Later row is waiting for: its earliest live plan after `day`.
    static func waitingDays(_ r: any StoreReader, after day: LocalDay, among rows: [TodayRow]) throws -> [UUID: LocalDay] {
        let ids = Set(rows.filter { $0.item.state == .later }.map(\.id))
        guard !ids.isEmpty else { return [:] }
        var days: [UUID: LocalDay] = [:]
        for plan in try r.plans(from: day.adding(days: 1)) where ids.contains(plan.itemId) {
            if days[plan.itemId].map({ plan.localDay < $0 }) ?? true { days[plan.itemId] = plan.localDay }
        }
        return days
    }

    /// The day this item waits for, if any.
    public func laterDay(itemId: UUID) throws -> LocalDay? {
        let day = currentDay()
        return try storeForQueries.read { r in
            try r.plans(from: day.adding(days: 1)).filter { $0.itemId == itemId }.map(\.localDay).min()
        }
    }

    /// Gives the item a day (or none, `nil`). A task of Today's own goes to Later first
    /// (as Move to Later); a Later task moved to Today goes back down (as Move to Goals &
    /// Later); one already in Goals & Later keeps its place. A day must be after today.
    public func setLaterDay(itemId: UUID, day newDay: LocalDay?) throws {
        let now = clockForQueries.now()
        let today = currentDay()
        if let newDay, newDay <= today { throw ClewError.notAllowed }
        try storeForQueries.write { w in
            try setLaterDay(itemId: itemId, day: newDay, today: today, now: now, w)
        }
    }

    func setLaterDay(itemId: UUID, day newDay: LocalDay?, today: LocalDay, now: Date, _ w: any StoreWriter) throws {
        guard var item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
        let list = try todayList(w, on: today)
        guard let row = (list.rows + list.goalsAndLater).first(where: { $0.id == itemId }), Self.canHaveDay(row) else {
            throw ClewError.notAllowed
        }
        if list.moved.contains(itemId) {
            try voidPlans(of: itemId, on: today, now: now, w)
            try releaseBlocksLeftToday(today: today, now: now, w)
        } else if item.state == .active {
            // Today's own: to Later, at Goals & Later's end, off Today (as Move to Later).
            item.state = .later
            item.plannedDay = nil
            item.sortKey = (try w.maxSortKey() ?? 0) + 1
            item.updatedAt = now
            try w.update(item)
            try voidPlans(of: itemId, on: today, now: now, w)
            try releaseBlocksLeftToday(today: today, now: now, w)
        }
        try voidDaysAhead(of: itemId, after: today, now: now, w)
        if let newDay {
            try w.insert(Plan(id: newID(), itemId: itemId, localDay: newDay, at: now, source: .user, todaySortKey: nil))
        }
    }

    /// Voids the item's live plans after `day`: its day for Later.
    func voidDaysAhead(of itemId: UUID, after day: LocalDay, now: Date, _ w: any StoreWriter) throws {
        for plan in try w.plans(from: day.adding(days: 1)) where plan.itemId == itemId {
            try w.voidPlan(id: plan.id, at: now)
        }
    }

    /// On its day, a plan booked ahead gets a Today place at the end, in the order the
    /// days were set (void + insert, as a reorder does). Only plans recorded before the
    /// day began; a nil-key plan made that day keeps the item's own key. Returns whether
    /// anything changed. Run on refresh, with `settleBlocks()`.
    @discardableResult
    public func settlePlans() throws -> Bool {
        let now = clockForQueries.now()
        let today = currentDay()
        let start = dayBounds(today).start
        return try storeForQueries.write { w in
            let moved = try todayList(w, on: today).moved
            let booked = try w.plans(on: today).filter {
                $0.todaySortKey == nil && $0.at < start && moved.contains($0.itemId)
            }
            for plan in booked {
                try w.voidPlan(id: plan.id, at: now)
                let key = (try w.maxSortKey() ?? 0) + 1
                try w.insert(Plan(id: newID(), itemId: plan.itemId, localDay: today, at: now, source: plan.source,
                                  todaySortKey: key))
            }
            return !booked.isEmpty
        }
    }
}
