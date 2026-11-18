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

    /// The latest live tick on `day` (in the current round, for a goal): what a rating
    /// applies to.
    func lastTick(on day: LocalDay) -> CheckIn? {
        counted.filter { $0.localDay == day }.max { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
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
        // Goals live in Goals & Later (SPEC 2026-11-15): never due on Today by
        // themselves, only when moved there (see `todayList`).
        return .notDue
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
    /// Today's latest live tick, if any: the one rating dots rate.
    public let lastTickToday: CheckIn?

    public init(item: Item, state: DueState, todayAmount: Int, progressAmount: Int, lastTickToday: CheckIn?) {
        self.item = item
        self.state = state
        self.todayAmount = todayAmount
        self.progressAmount = progressAmount
        self.lastTickToday = lastTickToday
    }

    public var id: UUID { item.id }
    public var isDone: Bool { state == .doneToday }
    /// A counted goal whose current round has reached its target.
    public var isGoalReached: Bool {
        item.progress.target.map { progressAmount >= $0 } ?? false
    }
}

public struct TodayList: Hashable, Sendable {
    public let day: LocalDay
    /// Today: what is due today, and what was moved here for today.
    public let rows: [TodayRow]
    /// Goals & Later (SPEC 2026-11-15): goals not reached and Later items not done,
    /// minus those moved to Today.
    public let goalsAndLater: [TodayRow]
    /// Items moved to Today for this day (live plans).
    public let moved: Set<UUID>

    public init(day: LocalDay, rows: [TodayRow], goalsAndLater: [TodayRow] = [], moved: Set<UUID> = []) {
        self.day = day
        self.rows = rows
        self.goalsAndLater = goalsAndLater
        self.moved = moved
    }

    /// Goals & Later rows ticked today count without moving ("4/4", never "3/3 +1").
    private var tickedBelow: Int { goalsAndLater.lazy.filter(\.isDone).count }
    /// The `done/total` title: Today's rows, plus anything ticked in Goals & Later.
    public var done: Int { rows.lazy.filter(\.isDone).count + tickedBelow }
    public var total: Int { rows.count + tickedBelow }
    /// Everything counted is done (and there is something): "All done for today".
    public var allDone: Bool { total > 0 && done == total }
}

/// Pure: Today's list and Goals & Later (SPEC 2026-11-15). Visible rows are `.due` and
/// `.doneToday`; ticked rows stay until rollover so undo is one click away and nothing
/// vanishes under the pointer. Order is stable (sort key, then creation), so a row
/// never moves when ticked.
/// - items: `.active` and `.later` items (collection items left out by the caller).
/// - planned: items moved to Today for `day`, with their plan's Today sort key (nil:
///   a plan from before 2026-11-15; the item's own `sortKey` is used).
/// - keepReached: goals reached by a time block's tick made today for an earlier day
///   (the Mac slept through it) keep their row, so their congratulation shows.
public func todayList(items: [Item], facts: [UUID: ItemFacts], on day: LocalDay,
                      keepReached: Set<UUID> = [], planned: [UUID: Double?] = [:]) -> TodayList {
    var today: [(key: Double, row: TodayRow)] = []
    var below: [(key: Double, row: TodayRow)] = []
    var moved: Set<UUID> = []
    for item in items where item.deletedAt == nil && (item.state == .active || item.state == .later) {
        let f = facts[item.id] ?? .empty
        let tickedToday = f.amount(on: day) > 0
        func row(_ state: DueState) -> TodayRow {
            TodayRow(item: item, state: state, todayAmount: f.amount(on: day), progressAmount: f.progressAmount,
                     lastTickToday: f.lastTick(on: day))
        }
        let reached = item.progress.target.map { f.progressAmount >= $0 } ?? false
        // A once task or link with a tick on an earlier day is done: gone from both lists.
        let doneBefore = (item.kind == .once || item.kind == .link) && f.progressAmount > 0 && !tickedToday
        // A reached goal keeps its row on the day it was reached (or by a late tick),
        // then hides until Next round or Raise target (as before).
        let hiddenGoal = item.kind == .goal && reached && !tickedToday && !keepReached.contains(item.id)
        let state: DueState = tickedToday ? .doneToday : .due
        // Only goals and Later items are moved: a once task, link or habit of Today's own
        // (an item picked from Later before 2026-11-15 has a plan too) stays by its own
        // rules and sort key.
        if let key = planned[item.id], item.kind == .goal || item.state == .later {
            guard !doneBefore, !hiddenGoal else { continue }
            moved.insert(item.id)
            today.append((key ?? item.sortKey, row(state)))
            continue
        }
        switch (item.kind, item.state) {
        case (.goal, .active):
            guard !hiddenGoal else { continue }
            // A late tick's goal shows its row, but that tick is yesterday's: not counted.
            below.append((item.sortKey, row(state)))
        case (.once, .later), (.link, .later):
            guard !doneBefore else { continue }
            below.append((item.sortKey, row(state)))
        case (_, .active):
            let due = dueState(item: item, on: day, facts: f)
            guard due == .due || due == .doneToday else { continue }
            today.append((item.sortKey, row(due)))
        default:
            continue
        }
    }
    func ordered(_ rows: [(key: Double, row: TodayRow)]) -> [TodayRow] {
        rows.sorted { a, b in
            (a.key, a.row.item.createdAt, a.row.item.id.uuidString) < (b.key, b.row.item.createdAt, b.row.item.id.uuidString)
        }.map(\.row)
    }
    return TodayList(day: day, rows: ordered(today), goalsAndLater: ordered(below), moved: moved)
}

/// The clock, injected. Domain and Core never call `Date()` (AGENTS.md rule 5).
public protocol Clock: Sendable {
    func now() -> Date
}

/// The current time zone, injected for the same reason.
public protocol TimeZoneSource: Sendable {
    func current() -> TimeZone
}
