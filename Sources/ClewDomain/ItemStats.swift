import Foundation

/// A task's history for its details page. Deliberately no streaks and nothing about
/// days without ticks (SPEC: no shame): only what got done.
public struct ItemStats: Hashable, Sendable {
    /// Distinct days with a tick in this ISO week (Monday start), today included.
    public let daysThisWeek: Int
    /// Distinct days with a tick in the 30 days ending today.
    public let daysLast30: Int
    /// Distinct days with a tick, all time.
    public let daysAllTime: Int
    /// Sum of amounts, all time (for a goal: every +1 across all rounds).
    public let totalAmount: Int
    /// For a goal: rounds whose target was reached (every next round implies one,
    /// plus the current round if it is reached).
    public let roundsFinished: Int?
    /// Amount per day for the heatmap window.
    public let amountByDay: [LocalDay: Int]
    /// How rated ticks felt: rating (1 meh, 2 fine, 3 great) → count. Empty when
    /// nothing was rated (rating dots are off by default).
    public let feltCounts: [Int: Int]

    /// - Parameters:
    ///   - checkIns: the item's check-ins (voided ones are ignored).
    ///   - rounds: the item's goal rounds (voided ones are ignored).
    ///   - currentRoundAmount: progress in the current round, for a goal.
    public init(item: Item, checkIns: [CheckIn], rounds: [GoalRound], currentRoundAmount: Int, today: LocalDay) {
        let live = checkIns.filter { !$0.isVoided && $0.localDay <= today }
        var byDay: [LocalDay: Int] = [:]
        for c in live { byDay[c.localDay, default: 0] += c.amount }
        let days = Set(byDay.keys)
        daysThisWeek = days.filter { $0.isInSameWeek(as: today) }.count
        daysLast30 = days.filter { $0 > today.adding(days: -30) }.count
        daysAllTime = days.count
        totalAmount = live.reduce(0) { $0 + $1.amount }
        if let target = item.progress.target {
            let earlier = rounds.filter { $0.voidedAt == nil }.count
            roundsFinished = earlier + (currentRoundAmount >= target ? 1 : 0)
        } else {
            roundsFinished = nil
        }
        amountByDay = byDay
        feltCounts = live.compactMap(\.rating).filter { (1...3).contains($0) }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}

/// The days of a GitHub-style grid: `weeks` columns, each Monday…Sunday, the last
/// column holding today's week. Days after today are nil (drawn empty).
public func heatmapColumns(endingAt today: LocalDay, weeks: Int) -> [[LocalDay?]] {
    let firstMonday = today.weekStart.adding(days: -7 * (weeks - 1))
    return (0..<weeks).map { week in
        (0..<7).map { weekday in
            let day = firstMonday.adding(days: week * 7 + weekday)
            return day <= today ? day : nil
        }
    }
}
