import Foundation

/// An item's state on one day (ARCHITECTURE §4.4).
public enum DueState: Hashable, Sendable {
    case due
    case doneToday
    /// A `timesPerWeek(n)` habit with check-ins on n distinct days this ISO week.
    case satisfiedThisWeek
    case notDue
}

/// The facts `dueState` needs about one item.
public struct ItemFacts: Hashable, Sendable {
    /// This item's check-ins from (at least) the Monday of the evaluated day's ISO week
    /// onward. Voided check-ins may be included; they are ignored.
    public var recent: [CheckIn]
    /// Sum of `amount` over all non-voided check-ins, all time.
    public var lifetimeAmount: Int

    public init(recent: [CheckIn], lifetimeAmount: Int) {
        self.recent = recent
        self.lifetimeAmount = lifetimeAmount
    }

    public static let empty = ItemFacts(recent: [], lifetimeAmount: 0)

    func amount(on day: LocalDay) -> Int {
        recent.lazy.filter { !$0.isVoided && $0.localDay == day }.reduce(0) { $0 + $1.amount }
    }

    func distinctDays(inWeekOf day: LocalDay) -> Int {
        Set(recent.lazy.filter { !$0.isVoided && $0.localDay.isInSameWeek(as: day) }.map(\.localDay)).count
    }
}

/// Pure: whether `item` belongs on Today's list for `day`, and how.
public func dueState(item: Item, on day: LocalDay, facts: ItemFacts) -> DueState {
    guard item.state == .active, item.deletedAt == nil else { return .notDue }
    let tickedToday = facts.amount(on: day) > 0

    switch item.kind {
    case .once, .link:
        // "Quietly moves to tomorrow" is this rule: an unfinished item planned for any
        // earlier day is due today. Nothing rewrites `plannedDay`.
        guard let planned = item.plannedDay, planned <= day else { return .notDue }
        if tickedToday { return .doneToday }
        return facts.lifetimeAmount > 0 ? .notDue : .due

    case .habit:
        return scheduledState(item.schedule, on: day, tickedToday: tickedToday, facts: facts)

    case .goal:
        // A finished goal stays visible on the day it was finished, then leaves.
        if let target = item.progress.target, facts.lifetimeAmount >= target, !tickedToday {
            return .notDue
        }
        return scheduledState(item.schedule, on: day, tickedToday: tickedToday, facts: facts)
    }
}

private func scheduledState(_ schedule: Schedule, on day: LocalDay, tickedToday: Bool, facts: ItemFacts) -> DueState {
    if tickedToday { return .doneToday }
    switch schedule {
    case .daily:
        return .due
    case .weekdays(let days):
        return days.contains(day.weekday) ? .due : .notDue
    case .timesPerWeek(let n):
        // A week where n is no longer reachable still shows `.due`: doing one is fine,
        // and "behind" is never shown.
        return facts.distinctDays(inWeekOf: day) >= n ? .satisfiedThisWeek : .due
    case .unscheduled:
        return .notDue
    }
}

public struct TodayRow: Hashable, Sendable, Identifiable {
    public let item: Item
    public let state: DueState
    /// Sum of today's non-voided check-in amounts.
    public let todayAmount: Int
    /// Lifetime total, for a counted goal's bar.
    public let lifetimeAmount: Int

    public var id: UUID { item.id }
    public var isDone: Bool { state == .doneToday }
}

public struct TodayList: Hashable, Sendable {
    public let day: LocalDay
    public let rows: [TodayRow]

    public init(day: LocalDay, rows: [TodayRow]) {
        self.day = day
        self.rows = rows
    }

    /// The `done/total` title counts exactly the visible rows.
    public var done: Int { rows.lazy.filter(\.isDone).count }
    public var total: Int { rows.count }
}

/// Pure: Today's list. Visible rows are `.due` and `.doneToday`; ticked rows stay
/// until rollover so undo is one click away and nothing vanishes under the pointer.
/// Order is stable (`sortKey`, then creation), so a row never moves when ticked.
public func todayList(items: [Item], facts: [UUID: ItemFacts], on day: LocalDay) -> TodayList {
    let rows = items
        .sorted { ($0.sortKey, $0.createdAt, $0.id.uuidString) < ($1.sortKey, $1.createdAt, $1.id.uuidString) }
        .compactMap { item -> TodayRow? in
            let f = facts[item.id] ?? .empty
            let state = dueState(item: item, on: day, facts: f)
            guard state == .due || state == .doneToday else { return nil }
            return TodayRow(item: item, state: state, todayAmount: f.amount(on: day), lifetimeAmount: f.lifetimeAmount)
        }
    return TodayList(day: day, rows: rows)
}

/// The clock, injected. Domain and Core never call `Date()` (AGENTS.md rule 5).
public protocol Clock: Sendable {
    func now() -> Date
}

/// The current time zone, injected for the same reason.
public protocol TimeZoneSource: Sendable {
    func current() -> TimeZone
}
