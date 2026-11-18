import ClewDomain
import Foundation
import Testing

/// SPEC 2026-11-18, "Done so far": the running total, its range and the goal dots.
@Suite struct DoneSoFarTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func item(_ kind: ItemKind, target: Int = 3) -> Item {
        Item(id: UUID(), kind: kind, title: "i", schedule: .daily,
             progress: kind == .goal ? .counter(target: target) : .none,
             state: .active, sortKey: 1, source: .user, createdAt: t0, updatedAt: t0)
    }
    func check(_ i: Item, _ d: String, _ amount: Int = 1, at minutes: Double = 0, voided: Bool = false) -> CheckIn {
        CheckIn(id: UUID(), itemId: i.id, localDay: day(d), at: t0.addingTimeInterval(minutes * 60),
                timeZoneId: "UTC", amount: amount, source: .user, voidedAt: voided ? t0 : nil)
    }
    func round(_ i: Item, at minutes: Double, target: Int, voided: Bool = false) -> GoalRound {
        GoalRound(id: UUID(), itemId: i.id, startedAt: t0.addingTimeInterval(minutes * 60), localDay: day("2026-11-01"),
                  target: target, source: .user, voidedAt: voided ? t0 : nil)
    }

    @Test func theTotalOnlyRisesAndStartsFromBeforeTheRange() {
        let done = DoneSoFar(perDay: [day("2026-11-01"): 2, day("2026-11-03"): 3, day("2026-11-05"): 1], goalReached: [])
        #expect(done.firstDay == day("2026-11-01"))
        #expect(done.total(through: day("2026-11-04")) == 5)
        let points = done.series(from: day("2026-11-03"), through: day("2026-11-06"))
        #expect(points.map(\.total) == [5, 5, 6, 6])                    // 2 before the range, then on
        #expect(points.map(\.added) == [3, 0, 1, 0])
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.total <= $1.total })
        #expect(done.series(from: day("2026-11-07"), through: day("2026-11-06")).isEmpty)
    }

    @Test func thePlotStartsTheDayBeforeAndThinsLongHistories() {
        // A first day alone: two points, so a line, rising by that day's count.
        let first = DoneSoFar(perDay: [day("2026-11-18"): 3], goalReached: [])
        #expect(first.plot(from: day("2026-11-18"), through: day("2026-11-18")).map(\.total) == [0, 3])
        #expect(first.plot(from: day("2026-11-18"), through: day("2026-11-18")).first?.day == day("2026-11-17"))
        // Long: one a week, the goal's day and the last day kept.
        var perDay: [LocalDay: Int] = [:]
        for i in 0..<1000 { perDay[day("2024-01-01").adding(days: i)] = 1 }
        let goal = day("2024-01-01").adding(days: 500)
        let long = DoneSoFar(perDay: perDay, goalReached: [goal])
        let points = long.plot(from: day("2024-01-01"), through: day("2024-01-01").adding(days: 999))
        #expect(points.count < 160 && points.last?.day == day("2024-01-01").adding(days: 999))
        #expect(points.contains { $0.day == goal && $0.goalReached })
        #expect(points.first?.total == 0 && points.last?.total == 1000)
        // Short ranges are daily.
        #expect(long.plot(from: day("2024-01-01"), through: day("2024-01-30")).count == 31)
    }

    @Test func rangesStartWhereTheSpecSays() {
        let today = day("2026-11-18")
        #expect(ProgressRange.days30.start(today: today, first: day("2026-01-01")) == day("2026-10-20"))
        #expect(ProgressRange.year.start(today: today, first: nil) == day("2025-11-19"))
        #expect(ProgressRange.all.start(today: today, first: day("2026-09-02")) == day("2026-09-02"))
        #expect(ProgressRange.all.start(today: today, first: nil) == today)
    }

    @Test func aGoalIsReachedWhenARoundsTotalIsMet() {
        let book = item(.goal, target: 5)
        let checks = [check(book, "2026-11-01", 2, at: 1), check(book, "2026-11-02", 3, at: 2),   // reached on the 2nd
                      check(book, "2026-11-03", 1, at: 4), check(book, "2026-11-04", 4, at: 5)]   // round 2: reached on the 4th
        let rounds = [round(book, at: 3, target: 5)]
        #expect(DoneSoFar.reachedDays(target: 5, rounds: rounds, checkIns: checks) == [day("2026-11-02"), day("2026-11-04")])
        // Not reached yet: no dot; an undone tick does not count.
        let undone = [check(book, "2026-11-01", 4, at: 1), check(book, "2026-11-02", 1, at: 2, voided: true)]
        #expect(DoneSoFar.reachedDays(target: 5, rounds: [], checkIns: undone).isEmpty)
    }

    @Test func raiseTargetCountsForTheCurrentRoundOnly() {
        // Round 1's total was 3 (recorded by round 2); the current round's was raised to 10.
        let book = item(.goal, target: 10)
        let checks = [check(book, "2026-11-01", 3, at: 1), check(book, "2026-11-02", 5, at: 3)]
        let rounds = [round(book, at: 2, target: 3)]
        #expect(DoneSoFar.reachedDays(target: 10, rounds: rounds, checkIns: checks) == [day("2026-11-01")])
        // A voided round does not split the ticks.
        #expect(DoneSoFar.reachedDays(target: 8, rounds: [round(book, at: 2, target: 3, voided: true)], checkIns: checks)
                == [day("2026-11-02")])
    }

    @Test func makeCountsOnceADayAndMarksGoalDays() {
        let book = item(.goal, target: 40), habit = item(.habit)
        let pages = check(book, "2026-11-02", 40)
        let done = DoneSoFar.make(
            ticks: [(pages, book), (check(habit, "2026-11-02"), habit), (check(habit, "2026-11-03"), habit)],
            goals: [(book, [], [pages])])
        #expect(done.perDay == [day("2026-11-02"): 2, day("2026-11-03"): 1])
        #expect(done.goalReached == [day("2026-11-02")])
        #expect(done.series(from: day("2026-11-02"), through: day("2026-11-03")).map(\.goalReached) == [true, false])
    }
}

/// A goal's Bars (SPEC 2026-11-18).
@Suite struct GoalDaysTests {
    @Test func thirtyDaysToTodayWithTheirSums() {
        let today = day("2026-11-18")
        let bars = GoalDays(amountByDay: [day("2026-11-18"): 38, day("2026-11-01"): 12, day("2026-10-20"): 5,
                                          day("2026-10-19"): 99, day("2026-11-05"): 38],
                            today: today)
        #expect(bars.days.count == 30)
        #expect(bars.days.first?.day == day("2026-10-20") && bars.days.last?.day == today)
        #expect(bars.total == 38 + 12 + 5 + 38 && bars.daysWorked == 4)        // the 19th is outside
        #expect(bars.most?.day == today && bars.most?.amount == 38)             // the latest of equal days
        #expect(GoalDays(amountByDay: [:], today: today).most == nil)
    }
}
