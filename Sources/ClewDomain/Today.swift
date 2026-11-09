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
    /// Sum of `amount` over non-voided check-ins that count toward progress: since
    /// `roundStart` for a goal in a later round, otherwise all time.
    public var progressAmount: Int
    /// When the goal's current round began (the latest `GoalRound`); nil for round 1
    /// and for every non-goal. Check-ins before it belong to earlier rounds.
    public var roundStart: Date?

    public init(recent: [CheckIn], progressAmount: Int, roundStart: Date? = nil) {
        self.recent = recent
        self.progressAmount = progressAmount
        self.roundStart = roundStart
    }

    public static let empty = ItemFacts(recent: [], progressAmount: 0)

    private var counted: some Sequence<CheckIn> {
        recent.lazy.filter { c in !c.isVoided && (roundStart.map { c.at >= $0 } ?? true) }
    }

    func amount(on day: LocalDay) -> Int {
        counted.filter { $0.localDay == day }.reduce(0) { $0 + $1.amount }
    }

    func distinctDays(inWeekOf day: LocalDay) -> Int {
        Set(counted.filter { $0.localDay.isInSameWeek(as: day) }.map(\.localDay)).count
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
        return facts.progressAmount > 0 ? .notDue : .due

    case .habit:
        return scheduledState(item.schedule, on: day, tickedToday: tickedToday, facts: facts)

    case .goal:
        // A reached goal stays visible on the day it was reached, then leaves, unless
        // a next round is started or the target raised.
        if let target = item.progress.target, facts.progressAmount >= target, !tickedToday {
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
    /// Sum of today's non-voided check-in amounts (in the current round, for a goal).
    public let todayAmount: Int
    /// Progress toward a counted goal's target, in the current round.
    public let progressAmount: Int

    public var id: UUID { item.id }
    public var isDone: Bool { state == .doneToday }
    /// A counted goal whose current round has reached its target.
    public var isGoalReached: Bool {
        item.progress.target.map { progressAmount >= $0 } ?? false
    }
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
            return TodayRow(item: item, state: state, todayAmount: f.amount(on: day), progressAmount: f.progressAmount)
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
