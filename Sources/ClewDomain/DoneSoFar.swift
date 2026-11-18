import Foundation

/// Settings › Progress › Done so far (SPEC 2026-11-18): a running total that only rises,
/// counted as `DoneCount` counts (each item once on each day it was done), with the
/// days a goal reached its total marked. Pure: Core passes the facts.
public struct DoneSoFar: Equatable, Sendable {
    /// Items done on each day.
    public let perDay: [LocalDay: Int]
    /// Days a goal reached its total.
    public let goalReached: Set<LocalDay>

    public init(perDay: [LocalDay: Int], goalReached: Set<LocalDay>) {
        self.perDay = perDay
        self.goalReached = goalReached
    }

    /// The first day anything was done.
    public var firstDay: LocalDay? { perDay.filter { $0.value > 0 }.keys.min() }

    /// Everything done up to and including `day`.
    public func total(through day: LocalDay) -> Int {
        perDay.reduce(0) { $1.key <= day ? $0 + $1.value : $0 }
    }

    public struct Point: Equatable, Sendable {
        public let day: LocalDay
        /// The running total at the end of the day.
        public let total: Int
        /// Done that day.
        public let added: Int
        /// A goal reached its total that day.
        public let goalReached: Bool
    }

    /// One point a day from `from` through `through` (nothing when `from` is later).
    public func series(from: LocalDay, through: LocalDay) -> [Point] {
        guard from <= through else { return [] }
        var running = total(through: from.adding(days: -1))
        return (0...(through.ordinal - from.ordinal)).map { offset in
            let day = from.adding(days: offset)
            let added = perDay[day] ?? 0
            running += added
            return Point(day: day, total: running, added: added, goalReached: goalReached.contains(day))
        }
    }

    /// - ticks: check-ins with their items (voided and deleted ones too: `DoneCount` decides).
    /// - goals: each goal (deleted ones too), with its rounds and its check-ins.
    public static func make(ticks: [(checkIn: CheckIn, item: Item)],
                            goals: [(item: Item, rounds: [GoalRound], checkIns: [CheckIn])]) -> DoneSoFar {
        var reached = Set<LocalDay>()
        for goal in goals {
            guard let target = goal.item.progress.target else { continue }
            reached.formUnion(reachedDays(target: target, rounds: goal.rounds, checkIns: goal.checkIns))
        }
        return DoneSoFar(perDay: DoneCount.byDay(ticks), goalReached: reached)
    }

    /// The days a goal reached its total, round by round. A round runs from its start
    /// (round 1 from the beginning) to the next round's start; its total is the next
    /// round's recorded total (Next round keeps the same total), and the current round's
    /// is the goal's own (Raise target changes it). Undone ticks and voided rounds do
    /// not count.
    public static func reachedDays(target: Int, rounds: [GoalRound], checkIns: [CheckIn]) -> [LocalDay] {
        let starts = rounds.filter { $0.voidedAt == nil }.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        let live = checkIns.filter { !$0.isVoided }.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
        var days: [LocalDay] = []
        for index in 0...starts.count {
            let begin = index == 0 ? Date.distantPast : starts[index - 1].startedAt
            let end = index < starts.count ? starts[index].startedAt : Date.distantFuture
            let total = index < starts.count ? starts[index].target : target
            var sum = 0
            for tick in live where tick.at >= begin && tick.at < end {
                sum += tick.amount
                if sum >= total {
                    days.append(tick.localDay)
                    break
                }
            }
        }
        return days
    }
}

/// Done so far's range (SPEC 2026-11-18): 30 days · Year · All, remembered.
public enum ProgressRange: String, CaseIterable, Sendable, Codable {
    case days30, year, all

    /// The first day shown: 30 days and a year end today; All starts at the first day
    /// anything was done (today when nothing was).
    public func start(today: LocalDay, first: LocalDay?) -> LocalDay {
        switch self {
        case .days30: today.adding(days: -29)
        case .year: today.adding(days: -364)
        case .all: min(first ?? today, today)
        }
    }
}

/// A goal's days as bars (SPEC 2026-11-18): the last `days` days to today, each day's
/// +1s (0 when none), and what they add up to.
public struct GoalDays: Equatable, Sendable {
    public let days: [(day: LocalDay, amount: Int)]

    public init(amountByDay: [LocalDay: Int], today: LocalDay, count: Int = 30) {
        days = (0..<count).map { offset in
            let day = today.adding(days: offset - count + 1)
            return (day, amountByDay[day] ?? 0)
        }
    }

    /// "+364 on 22 days".
    public var total: Int { days.reduce(0) { $0 + $1.amount } }
    public var daysWorked: Int { days.filter { $0.amount > 0 }.count }
    /// The highest day: the latest of equal ones.
    public var most: (day: LocalDay, amount: Int)? {
        days.filter { $0.amount > 0 }.max { ($0.amount, $0.day) < ($1.amount, $1.day) }
    }

    public static func == (a: GoalDays, b: GoalDays) -> Bool {
        a.days.map(\.day) == b.days.map(\.day) && a.days.map(\.amount) == b.days.map(\.amount)
    }
}
