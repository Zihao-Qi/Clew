import ClewDomain
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func item(
    _ kind: ItemKind, schedule: Schedule = .unscheduled, progress: ProgressSpec = .none,
    state: ItemState = .active, planned: LocalDay? = nil, sortKey: Double = 1, title: String = "x"
) -> Item {
    Item(id: UUID(), kind: kind, title: title, schedule: schedule, progress: progress, state: state,
         plannedDay: planned, sortKey: sortKey, source: .user, createdAt: t0, updatedAt: t0)
}

private func tick(_ item: Item, _ d: String, amount: Int = 1, voided: Bool = false) -> CheckIn {
    CheckIn(id: UUID(), itemId: item.id, localDay: day(d), at: t0, timeZoneId: "UTC", amount: amount,
            source: .user, voidedAt: voided ? t0 : nil)
}

private func facts(_ ticks: [CheckIn]) -> ItemFacts {
    ItemFacts(recent: ticks, progressAmount: ticks.filter { !$0.isVoided }.reduce(0) { $0 + $1.amount })
}

@Suite struct DueStateTests {
    // 2026-11-11 is a Wednesday; its week starts Monday 2026-11-09.
    let wed = day("2026-11-11")

    @Test func unfinishedOnceItemRollsForwardSilently() {
        let i = item(.once, planned: day("2026-11-05"))
        #expect(dueState(item: i, on: wed, facts: .empty) == .due)
    }

    @Test func onceItemPlannedForTheFutureIsNotDue() {
        let i = item(.once, planned: day("2026-11-12"))
        #expect(dueState(item: i, on: wed, facts: .empty) == .notDue)
    }

    @Test func onceItemTickedTodayStaysVisibleAsDone() {
        let i = item(.once, planned: wed)
        #expect(dueState(item: i, on: wed, facts: facts([tick(i, "2026-11-11")])) == .doneToday)
    }

    @Test func onceItemDoneOnAnEarlierDayIsGone() {
        let i = item(.once, planned: day("2026-11-10"))
        #expect(dueState(item: i, on: wed, facts: facts([tick(i, "2026-11-10")])) == .notDue)
    }

    @Test func voidedTickDoesNotCount() {
        let i = item(.once, planned: wed)
        #expect(dueState(item: i, on: wed, facts: facts([tick(i, "2026-11-11", voided: true)])) == .due)
    }

    @Test func laterAndArchivedItemsAreNeverOnToday() {
        #expect(dueState(item: item(.link, state: .later, planned: wed), on: wed, facts: .empty) == .notDue)
        #expect(dueState(item: item(.habit, schedule: .daily, state: .archived), on: wed, facts: .empty) == .notDue)
        var deleted = item(.habit, schedule: .daily)
        deleted.deletedAt = t0
        #expect(dueState(item: deleted, on: wed, facts: .empty) == .notDue)
    }

    @Test func weekdayHabitIsDueOnlyOnItsDays() {
        let i = item(.habit, schedule: .weekdays([.monday, .wednesday]))
        #expect(dueState(item: i, on: wed, facts: .empty) == .due)
        #expect(dueState(item: i, on: day("2026-11-12"), facts: .empty) == .notDue)
        #expect(dueState(item: i, on: wed, facts: facts([tick(i, "2026-11-11")])) == .doneToday)
    }

    @Test func dailyHabitIsDueAgainTheNextDay() {
        let i = item(.habit, schedule: .daily)
        #expect(dueState(item: i, on: day("2026-11-12"), facts: facts([tick(i, "2026-11-11")])) == .due)
    }

    @Test func timesPerWeekLeavesTodayOnceMetUnlessTickedToday() {
        let i = item(.habit, schedule: .timesPerWeek(2))
        let mon = tick(i, "2026-11-09"), tue = tick(i, "2026-11-10")
        #expect(dueState(item: i, on: wed, facts: facts([mon])) == .due)
        #expect(dueState(item: i, on: wed, facts: facts([mon, tue])) == .satisfiedThisWeek)
        // The day the target is met, it stays visible as done.
        #expect(dueState(item: i, on: day("2026-11-10"), facts: facts([mon, tue])) == .doneToday)
        // Two ticks on one day are one day.
        #expect(dueState(item: i, on: wed, facts: facts([mon, tick(i, "2026-11-09")])) == .due)
    }

    /// The en_US trap (ARCHITECTURE §4.3): with Sunday-start weeks, Sunday 2026-11-15
    /// would fall into a new week and the item would reappear.
    @Test func timesPerWeekCountsSundayInTheMondayWeek() {
        let i = item(.habit, schedule: .timesPerWeek(2))
        let f = facts([tick(i, "2026-11-09"), tick(i, "2026-11-13")])
        #expect(dueState(item: i, on: day("2026-11-15"), facts: f) == .satisfiedThisWeek)
        // and resets on Monday.
        #expect(dueState(item: i, on: day("2026-11-16"), facts: f) == .due)
    }

    /// SPEC 2026-11-15: a goal lives in Goals & Later, never on Today by itself; done
    /// today after one +1; a reached goal stays the day it was reached, then hides.
    @Test func goalIsDoneTodayAfterOnePlusOneAndLeavesWhenFinished() {
        let i = item(.goal, schedule: .daily, progress: .counter(target: 3))
        func below(_ f: ItemFacts) -> TodayRow? {
            let list = todayList(items: [i], facts: [i.id: f], on: wed)
            #expect(list.rows.isEmpty)
            return list.goalsAndLater.first
        }
        #expect(dueState(item: i, on: wed, facts: facts([tick(i, "2026-11-10")])) == .notDue)
        #expect(below(facts([tick(i, "2026-11-10")]))?.state == .due)
        #expect(below(facts([tick(i, "2026-11-11")]))?.state == .doneToday)
        let finishedYesterday = facts([tick(i, "2026-11-09"), tick(i, "2026-11-10", amount: 2)])
        #expect(below(finishedYesterday) == nil)
        // Finished today: it stays until rollover, so it never vanishes under the pointer.
        let finishedToday = facts([tick(i, "2026-11-10", amount: 2), tick(i, "2026-11-11")])
        #expect(below(finishedToday)?.state == .doneToday)
    }
}

@Suite struct GoalRoundTests {
    let wed = day("2026-11-11")

    @Test func ticksBeforeTheRoundStartDoNotCountToday() {
        let g = item(.goal, schedule: .daily, progress: .counter(target: 3))
        // Reached 3/3 this morning (at t0), then started a next round an hour later.
        let morning = tick(g, "2026-11-11", amount: 3)
        let f = ItemFacts(recent: [morning], progressAmount: 0, roundStart: t0.addingTimeInterval(3600))
        let row = todayList(items: [g], facts: [g.id: f], on: wed).goalsAndLater[0]
        #expect(row.state == .due)
        #expect(row.todayAmount == 0)
        #expect(!row.isGoalReached)
    }

    @Test func goalIsReachedAtItsTarget() {
        let g = item(.goal, schedule: .daily, progress: .counter(target: 3))
        let f = facts([tick(g, "2026-11-10", amount: 2), tick(g, "2026-11-11")])
        let row = todayList(items: [g], facts: [g.id: f], on: wed).goalsAndLater[0]
        #expect(row.isGoalReached && row.isDone)
        let short = facts([tick(g, "2026-11-11", amount: 2)])
        #expect(!todayList(items: [g], facts: [g.id: short], on: wed).goalsAndLater[0].isGoalReached)
    }
}

@Suite struct TodayListTests {
    let wed = day("2026-11-11")

    @Test func titleCountsExactlyTheVisibleRows() {
        let a = item(.habit, schedule: .daily, sortKey: 1)
        let b = item(.once, planned: wed, sortKey: 2)
        let hidden = item(.habit, schedule: .timesPerWeek(1), sortKey: 3)
        let notToday = item(.habit, schedule: .weekdays([.friday]), sortKey: 4)
        let list = todayList(
            items: [notToday, hidden, b, a],
            facts: [a.id: facts([tick(a, "2026-11-11")]), hidden.id: facts([tick(hidden, "2026-11-09")])],
            on: wed
        )
        #expect(list.rows.map(\.id) == [a.id, b.id])
        #expect(list.done == 1)
        #expect(list.total == 2)
    }

    @Test func rowsKeepTheirOrderWhenTicked() {
        // sortKey decides, even against creation time and id order.
        var a = item(.habit, schedule: .daily, sortKey: 2, title: "a")
        a.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var b = item(.habit, schedule: .daily, sortKey: 1, title: "b")
        b.id = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!
        b.createdAt = t0.addingTimeInterval(60)
        let before = todayList(items: [a, b], facts: [:], on: wed)
        let after = todayList(items: [a, b], facts: [b.id: facts([tick(b, "2026-11-11")])], on: wed)
        #expect(before.rows.map(\.id) == [b.id, a.id])
        #expect(after.rows.map(\.id) == before.rows.map(\.id))
    }

    @Test func aRowKnowsTodaysLatestLiveTick() {
        let g = item(.goal, schedule: .daily, progress: .counter(target: 30))
        let morning = CheckIn(id: UUID(), itemId: g.id, localDay: wed, at: t0, timeZoneId: "UTC", source: .user)
        let noon = CheckIn(id: UUID(), itemId: g.id, localDay: wed, at: t0.addingTimeInterval(3600), timeZoneId: "UTC", source: .user)
        let undone = CheckIn(id: UUID(), itemId: g.id, localDay: wed, at: t0.addingTimeInterval(7200), timeZoneId: "UTC",
                             source: .user, voidedAt: t0)
        let yesterday = tick(g, "2026-11-10")
        let row = todayList(items: [g], facts: [g.id: facts([morning, noon, undone, yesterday])], on: wed).goalsAndLater[0]
        #expect(row.lastTickToday?.id == noon.id)
        let plain = item(.habit, schedule: .daily)
        #expect(todayList(items: [plain], facts: [:], on: wed).rows[0].lastTickToday == nil)
    }

    @Test func goalRowCarriesLifetimeAndTodayAmounts() {
        let g = item(.goal, schedule: .daily, progress: .counter(target: 30))
        let f = facts([tick(g, "2026-11-09", amount: 9), tick(g, "2026-11-11"), tick(g, "2026-11-11", voided: true)])
        let row = todayList(items: [g], facts: [g.id: f], on: wed).goalsAndLater[0]
        #expect(row.progressAmount == 10)
        #expect(row.todayAmount == 1)
    }
}

/// Property test (ARCHITECTURE §10): random days × random facts.
@Suite struct SchedulePropertyTests {
    @Test func timesPerWeekIsNeverDueAfterNDistinctDaysThatWeek() {
        var rng = SplitMix64(seed: 0xC1E3)
        for _ in 0..<3_000 {
            let n = Int.random(in: 1...7, using: &rng)
            let i = item(.habit, schedule: .timesPerWeek(n))
            let today = LocalDay(ordinal: Int.random(in: 0...30_000, using: &rng))
            // Random ticks from two weeks before to today.
            let ticks = (0..<Int.random(in: 0...12, using: &rng)).map { _ in
                tick(i, today.adding(days: -Int.random(in: 0...13, using: &rng)).description,
                     voided: Int.random(in: 0..<5, using: &rng) == 0)
            }
            let distinctThisWeek = Set(ticks.filter { !$0.isVoided && $0.localDay >= today.weekStart }.map(\.localDay)).count
            let state = dueState(item: i, on: today, facts: facts(ticks))
            let tickedToday = ticks.contains { !$0.isVoided && $0.localDay == today }
            if tickedToday {
                #expect(state == .doneToday)
            } else if distinctThisWeek >= n {
                #expect(state == .satisfiedThisWeek)
            } else {
                #expect(state == .due)
            }
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// SPEC 2026-11-15, "Today and Goals & Later": which list an item is in, the order, and
/// what counts.
@Suite struct GoalsAndLaterListTests {
    let wed = day("2026-11-11")

    @Test func goalsAndLaterItemsAreBelowAndOnlyTodayCounts() {
        let task = item(.once, planned: wed, sortKey: 1, title: "task")
        let habit = item(.habit, schedule: .daily, sortKey: 2, title: "habit")
        let goal = item(.goal, progress: .counter(target: 30), sortKey: 3, title: "goal")
        let later = item(.link, state: .later, sortKey: 4, title: "later")
        let list = todayList(items: [later, goal, habit, task], facts: [:], on: wed)
        #expect(list.rows.map(\.item.title) == ["task", "habit"])
        #expect(list.goalsAndLater.map(\.item.title) == ["goal", "later"])
        #expect(list.done == 0 && list.total == 2 && !list.allDone)
    }

    @Test func aTickBelowCountsWithoutMovingFourOfFour() {
        let task = item(.once, planned: wed, sortKey: 1, title: "task")
        let goal = item(.goal, progress: .counter(target: 30), sortKey: 2, title: "goal")
        let later = item(.once, state: .later, sortKey: 3, title: "later")
        let list = todayList(items: [task, goal, later],
                             facts: [task.id: facts([tick(task, "2026-11-11")]), goal.id: facts([tick(goal, "2026-11-11")])],
                             on: wed)
        #expect(list.rows.map(\.item.title) == ["task"])
        #expect(list.goalsAndLater.map(\.item.title) == ["goal", "later"])     // not moved
        #expect(list.done == 2 && list.total == 2 && list.allDone)            // 2/2, not 1/1 +1
        // Nothing done: no all-done; nothing at all: no all-done either.
        #expect(!todayList(items: [], facts: [:], on: wed).allDone)
    }

    @Test func aLaterItemDoneOnAnEarlierDayIsGoneFromBoth() {
        let later = item(.once, state: .later)
        let list = todayList(items: [later], facts: [later.id: facts([tick(later, "2026-11-10")])], on: wed)
        #expect(list.rows.isEmpty && list.goalsAndLater.isEmpty)
    }

    @Test func movedItemsAreOnTodayInTheirPlansPlace() {
        let a = item(.once, planned: wed, sortKey: 1, title: "a")
        let b = item(.once, planned: wed, sortKey: 3, title: "b")
        let goal = item(.goal, progress: .counter(target: 30), sortKey: 9, title: "goal")
        let later = item(.link, state: .later, sortKey: 0.5, title: "later")
        let old = item(.once, state: .later, sortKey: 2.5, title: "old pick")
        let planned: [UUID: Double?] = [goal.id: 2, later.id: 4, old.id: nil as Double?]
        let list = todayList(items: [a, b, goal, later, old], facts: [:], on: wed, planned: planned)
        // The goal's plan key 2 puts it between a and b; an old plan without a key uses
        // the item's own sort key (2.5).
        #expect(list.rows.map(\.item.title) == ["a", "goal", "old pick", "b", "later"])
        #expect(list.goalsAndLater.isEmpty)
        #expect(list.moved == [goal.id, later.id, old.id])
        #expect(list.total == 5)
        // Without the plans (the next day), they are back below in their own order.
        let next = todayList(items: [a, b, goal, later, old], facts: [:], on: wed)
        #expect(next.goalsAndLater.map(\.item.title) == ["later", "old pick", "goal"])
    }

    @Test func aReachedGoalStaysTheDayItWasReachedThenHides() {
        let goal = item(.goal, progress: .counter(target: 2))
        let reachedToday = facts([tick(goal, "2026-11-10"), tick(goal, "2026-11-11")])
        #expect(todayList(items: [goal], facts: [goal.id: reachedToday], on: wed).goalsAndLater.first?.isGoalReached == true)
        let reachedBefore = facts([tick(goal, "2026-11-09"), tick(goal, "2026-11-10")])
        #expect(todayList(items: [goal], facts: [goal.id: reachedBefore], on: wed).goalsAndLater.isEmpty)
        // A late tick (yesterday's) keeps its row today, not counted.
        let late = todayList(items: [goal], facts: [goal.id: reachedBefore], on: wed, keepReached: [goal.id])
        #expect(late.goalsAndLater.first?.isGoalReached == true && late.total == 0)
        // A reached goal is never on Today, even with a plan.
        #expect(todayList(items: [goal], facts: [goal.id: reachedBefore], on: wed, planned: [goal.id: 1]).rows.isEmpty)
    }

    @Test func habitsAndDeletedItemsNeverGoBelow() {
        let habit = item(.habit, schedule: .weekdays([.friday]))
        var gone = item(.goal, progress: .counter(target: 3))
        gone.deletedAt = t0
        let list = todayList(items: [habit, gone], facts: [:], on: wed)
        #expect(list.rows.isEmpty && list.goalsAndLater.isEmpty)
    }
}
