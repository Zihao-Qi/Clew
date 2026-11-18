import ClewDomain
import Foundation

/// Settings › Progress › Done so far, and a goal's Bars or Heatmap (SPEC 2026-11-18).
public enum GoalChart: String, CaseIterable, Sendable {
    case bars, heatmap
}

extension Clew {
    static let progressRangeKey = "progress.range"
    static let goalChartKey = "goalChart"

    /// Everything done so far: items done each day, counted in the store (one row a
    /// day; review: reading every +1 of a few years was slow), and the days a goal reached
    /// its total, from each goal's live ticks and rounds (a goal deleted since keeps its
    /// dots: history is kept, as its ticks are).
    public func doneSoFar() throws -> DoneSoFar {
        let today = currentDay()
        let beginning = LocalDay(year: 1, month: 1, day: 1)!
        return try storeForQueries.read { r in
            let goals = try r.goals()
            let ticks = Dictionary(grouping: try r.checkIns(itemIds: goals.map(\.id), from: beginning)
                .filter { $0.localDay <= today }, by: \.itemId)
            var reached = Set<LocalDay>()
            for goal in goals {
                guard let target = goal.progress.target else { continue }
                reached.formUnion(DoneSoFar.reachedDays(target: target, rounds: try r.goalRounds(itemId: goal.id),
                                                        checkIns: ticks[goal.id] ?? []))
            }
            return DoneSoFar(perDay: try r.doneByDay(through: today), goalReached: reached)
        }
    }

    /// Done so far's range, remembered (default All).
    public func progressRange() throws -> ProgressRange {
        try storeForQueries.read { r in
            try r.setting(Self.progressRangeKey).flatMap { ProgressRange(rawValue: $0.trimmingCharacters(in: ["\""])) }
        } ?? .all
    }

    public func setProgressRange(_ range: ProgressRange) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.progressRangeKey, json: "\"\(range.rawValue)\"", updatedAt: now) }
    }

    /// A goal's days as Bars or Heatmap, remembered for all goals (default Bars).
    public func goalChart() throws -> GoalChart {
        try storeForQueries.read { r in
            try r.setting(Self.goalChartKey).flatMap { GoalChart(rawValue: $0.trimmingCharacters(in: ["\""])) }
        } ?? .bars
    }

    public func setGoalChart(_ chart: GoalChart) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.goalChartKey, json: "\"\(chart.rawValue)\"", updatedAt: now) }
    }
}
