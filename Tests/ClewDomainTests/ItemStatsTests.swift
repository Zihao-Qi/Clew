import ClewDomain
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func goal(_ target: Int) -> Item {
    Item(id: UUID(), kind: .goal, title: "g", schedule: .daily, progress: .counter(target: target), state: .active,
         sortKey: 1, source: .user, createdAt: t0, updatedAt: t0)
}
private func habit() -> Item {
    Item(id: UUID(), kind: .habit, title: "h", schedule: .daily, progress: .none, state: .active,
         sortKey: 1, source: .user, createdAt: t0, updatedAt: t0)
}
private func tick(_ i: Item, _ d: String, _ amount: Int = 1, voided: Bool = false) -> CheckIn {
    CheckIn(id: UUID(), itemId: i.id, localDay: day(d), at: t0, timeZoneId: "UTC", amount: amount, source: .user,
            voidedAt: voided ? t0 : nil)
}

@Suite struct ItemStatsTests {
    // Wednesday 2026-11-11; its week started Monday 2026-11-09.
    let today = day("2026-11-11")

    @Test func countsDistinctDaysInEachWindow() {
        let h = habit()
        let ticks = [
            tick(h, "2026-11-11"), tick(h, "2026-11-11"), // one day
            tick(h, "2026-11-09"),                         // this week
            tick(h, "2026-11-08"),                         // Sunday: last week
            tick(h, "2026-10-13"),                         // 29 days ago: inside 30
            tick(h, "2026-10-12"),                         // 30 days ago: outside
            tick(h, "2026-11-10", voided: true),           // never counts
            tick(h, "2026-11-12"),                         // tomorrow (time-zone travel): not yet
        ]
        let s = ItemStats(item: h, checkIns: ticks, rounds: [], currentRoundAmount: 0, today: today)
        #expect(s.daysThisWeek == 2)
        #expect(s.daysLast30 == 4)
        #expect(s.daysAllTime == 5)
        #expect(s.totalAmount == 6)
        #expect(s.roundsFinished == nil)
        #expect(s.amountByDay[day("2026-11-11")] == 2)
        #expect(s.amountByDay[day("2026-11-10")] == nil)
    }

    @Test func goalRoundsFinishedCountsPastRoundsAndAReachedCurrentOne() {
        let g = goal(3)
        let r = GoalRound(id: UUID(), itemId: g.id, startedAt: t0, localDay: today, target: 3, source: .user)
        let voided = GoalRound(id: UUID(), itemId: g.id, startedAt: t0, localDay: today, target: 3, source: .user, voidedAt: t0)
        #expect(ItemStats(item: g, checkIns: [], rounds: [r, voided], currentRoundAmount: 2, today: today).roundsFinished == 1)
        #expect(ItemStats(item: g, checkIns: [], rounds: [r], currentRoundAmount: 3, today: today).roundsFinished == 2)
        #expect(ItemStats(item: g, checkIns: [], rounds: [], currentRoundAmount: 0, today: today).roundsFinished == 0)
    }
}

@Suite struct HeatmapTests {
    @Test func columnsAreMondayWeeksEndingWithTodaysWeek() {
        let cols = heatmapColumns(endingAt: day("2026-11-11"), weeks: 16)
        #expect(cols.count == 16 && cols.allSatisfy { $0.count == 7 })
        #expect(cols[0][0] == day("2026-07-27")) // a Monday, 15 weeks before Nov 9
        #expect(cols[15][0] == day("2026-11-09"))
        #expect(cols[15][2] == day("2026-11-11"))
        #expect(cols[15][3] == nil && cols[15][6] == nil) // future days are empty
        #expect(cols.joined().compactMap { $0 }.count == 15 * 7 + 3)
        #expect(cols.map { $0[0]! }.allSatisfy { $0.weekday == .monday })
    }

    @Test func aSundayEndsItsColumn() {
        let cols = heatmapColumns(endingAt: day("2026-11-15"), weeks: 2)
        #expect(cols[1].compactMap { $0 } == (9...15).map { day(String(format: "2026-11-%02d", $0)) })
    }
}
