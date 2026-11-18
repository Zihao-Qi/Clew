import ClewDomain
import Foundation

/// Settings › Progress › Done so far, and a goal's Bars or Heatmap (SPEC 2026-11-18).
public enum GoalChart: String, CaseIterable, Sendable {
    case bars, heatmap
}

extension Clew {
    static let progressRangeKey = "progress.range"
    static let goalChartKey = "goalChart"

    /// Everything done so far: every check-in up to today with its item (deleted items
    /// included, `DoneCount` decides), and each goal with its rounds (a goal deleted
    /// since keeps its dots: history is kept, as its ticks are).
    public func doneSoFar() throws -> DoneSoFar {
        let today = currentDay()
        let beginning = LocalDay(year: 1, month: 1, day: 1)!
        return try storeForQueries.read { r in
            let checkIns = try r.checkIns(from: beginning, through: today)
            var items: [UUID: Item] = [:]
            for id in Set(checkIns.map(\.itemId)) { items[id] = try r.item(id: id) }
            let ticks = checkIns.compactMap { c in items[c.itemId].map { (checkIn: c, item: $0) } }
            let byItem = Dictionary(grouping: checkIns, by: \.itemId)
            let goals = try items.values.filter { $0.kind == .goal }.map { goal in
                (item: goal, rounds: try r.goalRounds(itemId: goal.id), checkIns: byItem[goal.id] ?? [])
            }
            return DoneSoFar.make(ticks: ticks, goals: goals)
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
