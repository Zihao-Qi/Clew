import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func day(_ s: String) -> LocalDay { LocalDay(string: s)! }

private struct Harness {
    let store = FakeStore()
    let clock = TestClock(local(2026, 11, 11, 10)) // Wednesday
    let clew: Clew

    init() {
        clew = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
    }
}

@Suite struct AddItemTests {
    @Test func todayCreatesAOnceItemPlannedForTheCurrentDay() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "  Apply to 1 job \n", shape: .today))
        #expect(item.kind == .once)
        #expect(item.title == "Apply to 1 job")
        #expect(item.plannedDay == day("2026-11-11"))
        #expect(item.state == .active)
        #expect(item.source == .user)
        #expect(try h.clew.today().rows.map(\.id) == [item.id])
    }

    @Test func addingAt1amPlansForTheDayYouAreStillIn() throws {
        let h = Harness()
        h.clock.set(local(2026, 11, 12, 1))
        #expect(try h.clew.addItem(NewItem(title: "x", shape: .today)).plannedDay == day("2026-11-11"))
    }

    @Test func laterWithAURLIsALinkAndIsHiddenFromToday() throws {
        let h = Harness()
        let link = try h.clew.addItem(NewItem(title: "Talk", url: URL(string: "https://youtu.be/x"), shape: .later))
        let note = try h.clew.addItem(NewItem(title: "Idea", shape: .later))
        #expect(link.kind == .link)
        #expect(note.kind == .once)
        #expect(link.state == .later && link.plannedDay == nil)
        #expect(try h.clew.today().rows.isEmpty)
        #expect(try h.clew.laterCount() == 2)
    }

    @Test func newItemsGoToTheEnd() throws {
        let h = Harness()
        let a = try h.clew.addItem(NewItem(title: "a", shape: .habit(.daily)))
        let b = try h.clew.addItem(NewItem(title: "b", shape: .today))
        #expect(b.sortKey > a.sortKey)
        #expect(try h.clew.today().rows.map(\.id) == [a.id, b.id])
    }

    @Test func invalidInputIsRejectedAndNothingIsStored() throws {
        let h = Harness()
        #expect(throws: ClewError.emptyTitle) { try h.clew.addItem(NewItem(title: "  ", shape: .today)) }
        #expect(throws: ClewError.titleTooLong(max: 200)) {
            try h.clew.addItem(NewItem(title: String(repeating: "a", count: 201), shape: .today))
        }
        #expect(throws: ClewError.invalidURL) {
            try h.clew.addItem(NewItem(title: "x", url: URL(string: "file:///etc/passwd"), shape: .later))
        }
        #expect(throws: ClewError.invalidURL) {
            try h.clew.addItem(NewItem(title: "x", url: URL(string: "javascript:alert(1)"), shape: .later))
        }
        #expect(throws: ClewError.invalidTarget) {
            try h.clew.addItem(NewItem(title: "x", shape: .goal(target: 0, schedule: .daily)))
        }
        #expect(throws: ClewError.invalidSchedule) { try h.clew.addItem(NewItem(title: "x", shape: .habit(.weekdays([])))) }
        #expect(throws: ClewError.invalidSchedule) { try h.clew.addItem(NewItem(title: "x", shape: .habit(.timesPerWeek(8)))) }
        #expect(throws: ClewError.invalidSchedule) { try h.clew.addItem(NewItem(title: "x", shape: .habit(.unscheduled))) }
        #expect(h.store.state.items.isEmpty)
        // The boundaries themselves are valid.
        try h.clew.addItem(NewItem(title: String(repeating: "a", count: 200), shape: .habit(.timesPerWeek(7))))
        try h.clew.addItem(NewItem(title: "x", shape: .goal(target: 1, schedule: .daily)))
    }
}

@Suite struct CheckInTests {
    @Test func doubleClickOnAOnceItemRecordsOneCheckIn() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .today))
        let first = try h.clew.checkIn(itemId: item.id)
        let second = try h.clew.checkIn(itemId: item.id)
        #expect(first.id == second.id)
        #expect(h.store.state.checkIns.count == 1)
        let today = try h.clew.today()
        #expect(today.done == 1 && today.total == 1)
    }

    @Test func habitRecordsOneCheckInPerDay() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .habit(.daily)))
        try h.clew.checkIn(itemId: item.id)
        try h.clew.checkIn(itemId: item.id)
        h.clock.set(local(2026, 11, 12, 10))
        try h.clew.checkIn(itemId: item.id)
        #expect(h.store.state.checkIns.count == 2)
        #expect(Set(h.store.state.checkIns.values.map(\.localDay)) == [day("2026-11-11"), day("2026-11-12")])
    }

    @Test func goalRecordsPlusOneEveryClick() throws {
        let h = Harness()
        let goal = try h.clew.addItem(NewItem(title: "ML course", shape: .goal(target: 30, schedule: .daily)))
        for _ in 0..<3 { try h.clew.checkIn(itemId: goal.id) }
        let row = try #require(try h.clew.today().rows.first)
        #expect(row.progressAmount == 3)
        #expect(row.isDone)
    }

    @Test func checkInStoresTheDayZoneAndSource() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .habit(.daily)))
        h.clock.set(local(2026, 11, 12, 2)) // before rollover
        let c = try h.clew.checkIn(itemId: item.id, source: .notification)
        #expect(c.localDay == day("2026-11-11"))
        #expect(c.timeZoneId == "America/New_York")
        #expect(c.source == .notification)
        #expect(c.at == local(2026, 11, 12, 2))
    }

    @Test func laterItemsCannotBeTicked() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .later))
        #expect(throws: ClewError.notAllowed) { try h.clew.checkIn(itemId: item.id) }
        #expect(throws: ClewError.itemNotFound) { try h.clew.checkIn(itemId: UUID()) }
    }

    @Test func onceItemDoneYesterdayCannotBeDoneAgain() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .today))
        try h.clew.checkIn(itemId: item.id)
        h.clock.set(local(2026, 11, 12, 10))
        #expect(throws: ClewError.notAllowed) { try h.clew.checkIn(itemId: item.id) }
        #expect(try h.clew.today().rows.isEmpty)
    }

    @Test func todayReadsThisWeeksTicksAndLifetimeTotals() throws {
        let h = Harness()
        h.clock.set(local(2026, 11, 4, 10)) // the Wednesday before
        let goal = try h.clew.addItem(NewItem(title: "g", shape: .goal(target: 30, schedule: .daily)))
        let weekly = try h.clew.addItem(NewItem(title: "w", shape: .habit(.timesPerWeek(2))))
        try h.clew.checkIn(itemId: goal.id)
        try h.clew.checkIn(itemId: goal.id)
        h.clock.set(local(2026, 11, 9, 10)) // Monday
        try h.clew.checkIn(itemId: weekly.id)
        h.clock.set(local(2026, 11, 10, 10))
        try h.clew.checkIn(itemId: weekly.id)
        h.clock.set(local(2026, 11, 11, 10)) // Wednesday
        let today = try h.clew.today()
        #expect(today.rows.map(\.id) == [goal.id]) // weekly target met on Mon + Tue
        #expect(today.rows.first?.progressAmount == 2) // ticks from last week count
    }

    @Test func unfinishedOnceItemShowsUpTomorrow() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .today))
        h.clock.set(local(2026, 11, 14, 10))
        #expect(try h.clew.today().rows.map(\.id) == [item.id])
        // and nothing rewrote it.
        #expect(h.store.state.items[item.id]?.plannedDay == day("2026-11-11"))
    }
}

@Suite struct UndoTests {
    @Test func undoVoidsTodaysCheckInAndNeverDeletesIt() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .today))
        let c = try h.clew.checkIn(itemId: item.id)
        h.clock.set(local(2026, 11, 11, 10, 5))
        let voided = try #require(try h.clew.undoToday(itemId: item.id))
        #expect(voided.id == c.id)
        #expect(voided.voidedAt == local(2026, 11, 11, 10, 5))
        #expect(voided.voidReason == "undo")
        #expect(h.store.state.checkIns.count == 1)
        let row = try #require(try h.clew.today().rows.first)
        #expect(row.state == .due)
    }

    @Test func undoOnAGoalRemovesOnlyTheLastPlusOne() throws {
        let h = Harness()
        let goal = try h.clew.addItem(NewItem(title: "g", shape: .goal(target: 30, schedule: .daily)))
        try h.clew.checkIn(itemId: goal.id)
        h.clock.set(local(2026, 11, 11, 11))
        let last = try h.clew.checkIn(itemId: goal.id)
        #expect(try h.clew.undoToday(itemId: goal.id)?.id == last.id)
        #expect(try h.clew.today().rows.first?.progressAmount == 1)
    }

    @Test func undoDoesNotReachIntoEarlierDays() throws {
        let h = Harness()
        let goal = try h.clew.addItem(NewItem(title: "g", shape: .goal(target: 30, schedule: .daily)))
        try h.clew.checkIn(itemId: goal.id)
        h.clock.set(local(2026, 11, 12, 10))
        #expect(try h.clew.undoToday(itemId: goal.id) == nil)
        #expect(try h.clew.today().rows.first?.progressAmount == 1)
    }

    @Test func voidingAnUnknownCheckInIsAnError() {
        let h = Harness()
        #expect(throws: ClewError.checkInNotFound) { try h.clew.voidCheckIn(id: UUID(), reason: "x") }
    }

    @Test func voidingTwiceIsANoOp() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .habit(.daily)))
        let c = try h.clew.checkIn(itemId: item.id)
        try h.clew.voidCheckIn(id: c.id, reason: "first")
        h.clock.set(local(2026, 11, 11, 12))
        try h.clew.voidCheckIn(id: c.id, reason: "second")
        #expect(h.store.state.checkIns[c.id]?.voidReason == "first")
        #expect(h.store.state.checkIns[c.id]?.voidedAt == local(2026, 11, 11, 10))
    }
}

@Suite struct LaterTests {
    @Test func pickingMovesItemsToTodayAndRecordsPlans() throws {
        let h = Harness()
        let a = try h.clew.addItem(NewItem(title: "a", url: URL(string: "https://a.example"), shape: .later))
        let b = try h.clew.addItem(NewItem(title: "b", shape: .later))
        let habit = try h.clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        try h.clew.planForToday(itemIds: [b.id, a.id])
        let today = try h.clew.today()
        #expect(today.rows.map(\.id) == [habit.id, b.id, a.id])
        #expect(try h.clew.laterCount() == 0)
        let plans = h.store.state.plans.values
        #expect(Set(plans.map(\.itemId)) == [a.id, b.id])
        #expect(plans.allSatisfy { $0.localDay == day("2026-11-11") && $0.source == .user })
    }

    @Test func pickingAllowsOneToThreeDistinctItems() throws {
        let h = Harness()
        let ids = try (0..<4).map { try h.clew.addItem(NewItem(title: "\($0)", shape: .later)).id }
        #expect(throws: ClewError.pickCount) { try h.clew.planForToday(itemIds: []) }
        #expect(throws: ClewError.pickCount) { try h.clew.planForToday(itemIds: ids) }
        try h.clew.planForToday(itemIds: [ids[0], ids[0], ids[1], ids[2]])
        #expect(h.store.state.plans.count == 3)
    }

    @Test func aFailedPickChangesNothing() throws {
        let h = Harness()
        let later = try h.clew.addItem(NewItem(title: "l", shape: .later))
        let active = try h.clew.addItem(NewItem(title: "a", shape: .today))
        #expect(throws: ClewError.notAllowed) { try h.clew.planForToday(itemIds: [later.id, active.id]) }
        #expect(h.store.state.items[later.id]?.state == .later)
        #expect(h.store.state.plans.isEmpty)
    }

    @Test func moveToLaterOnlyForUnfinishedOnceItemsAndLinks() throws {
        let h = Harness()
        let once = try h.clew.addItem(NewItem(title: "o", shape: .today))
        let habit = try h.clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        let done = try h.clew.addItem(NewItem(title: "d", shape: .today))
        try h.clew.checkIn(itemId: done.id)
        try h.clew.moveToLater(itemId: once.id)
        #expect(h.store.state.items[once.id]?.state == .later)
        #expect(h.store.state.items[once.id]?.plannedDay == nil)
        #expect(throws: ClewError.notAllowed) { try h.clew.moveToLater(itemId: habit.id) }
        #expect(throws: ClewError.notAllowed) { try h.clew.moveToLater(itemId: done.id) }
    }

    @Test func laterItemsAreNewestFirst() throws {
        let h = Harness()
        let old = try h.clew.addItem(NewItem(title: "old", shape: .later))
        h.clock.set(local(2026, 11, 11, 11))
        let new = try h.clew.addItem(NewItem(title: "new", shape: .later))
        #expect(try h.clew.laterItems().map(\.id) == [new.id, old.id])
    }
}

@Suite struct GoalRoundCommandTests {
    private func reachedGoal(_ h: Harness, target: Int = 2) throws -> Item {
        let goal = try h.clew.addItem(NewItem(title: "g", shape: .goal(target: target, schedule: .daily)))
        for _ in 0..<target { try h.clew.checkIn(itemId: goal.id) }
        return goal
    }

    @Test func reachingTheTargetStopsCountingAndStaysVisible() throws {
        let h = Harness()
        let goal = try reachedGoal(h)
        #expect(throws: ClewError.goalReached) { try h.clew.checkIn(itemId: goal.id) }
        let row = try #require(try h.clew.today().rows.first)
        #expect(row.progressAmount == 2 && row.isGoalReached && row.isDone)
        // The next day it has left the list.
        h.clock.set(local(2026, 11, 12, 10))
        #expect(try h.clew.today().rows.isEmpty)
    }

    @Test func nextRoundStartsFromZeroAndKeepsHistory() throws {
        let h = Harness()
        let goal = try reachedGoal(h)
        h.clock.set(local(2026, 11, 11, 11))
        let round = try h.clew.startNextRound(itemId: goal.id)
        #expect(round.target == 2 && round.localDay == day("2026-11-11") && round.startedAt == local(2026, 11, 11, 11))
        var row = try #require(try h.clew.today().rows.first)
        #expect(row.progressAmount == 0 && row.state == .due)
        h.clock.set(local(2026, 11, 11, 12))
        try h.clew.checkIn(itemId: goal.id)
        row = try #require(try h.clew.today().rows.first)
        #expect(row.progressAmount == 1 && row.todayAmount == 1)
        #expect(h.store.state.checkIns.count == 3) // round 1 is still in the history
    }

    @Test func nextRoundOnlyAfterTheTargetIsReached() throws {
        let h = Harness()
        let goal = try h.clew.addItem(NewItem(title: "g", shape: .goal(target: 5, schedule: .daily)))
        try h.clew.checkIn(itemId: goal.id)
        #expect(throws: ClewError.notAllowed) { try h.clew.startNextRound(itemId: goal.id) }
        let habit = try h.clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        try h.clew.checkIn(itemId: habit.id)
        #expect(throws: ClewError.notAllowed) { try h.clew.startNextRound(itemId: habit.id) }
        #expect(h.store.state.rounds.isEmpty)
    }

    @Test func raisingTheTargetLetsCountingContinue() throws {
        let h = Harness()
        let goal = try reachedGoal(h)
        try h.clew.editItem(id: goal.id, ItemEdit(title: "g", url: nil, schedule: .daily, target: 4))
        try h.clew.checkIn(itemId: goal.id)
        let row = try #require(try h.clew.today().rows.first)
        #expect(row.progressAmount == 3 && !row.isGoalReached)
    }

    @Test func undoAfterANextRoundNeverReachesIntoTheLastRound() throws {
        let h = Harness()
        let goal = try reachedGoal(h)
        h.clock.set(local(2026, 11, 11, 11))
        try h.clew.startNextRound(itemId: goal.id)
        #expect(try h.clew.undoToday(itemId: goal.id) == nil)
        #expect(h.store.state.checkIns.values.allSatisfy { !$0.isVoided })
    }
}

@Suite struct DeleteTests {
    @Test func deleteIsATombstoneThatKeepsHistory() throws {
        let h = Harness()
        let habit = try h.clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        let later = try h.clew.addItem(NewItem(title: "l", shape: .later))
        try h.clew.checkIn(itemId: habit.id)
        h.clock.set(local(2026, 11, 11, 12))
        try h.clew.deleteItem(itemId: habit.id)
        try h.clew.deleteItem(itemId: later.id)
        #expect(try h.clew.today().rows.isEmpty)
        #expect(try h.clew.laterCount() == 0)
        #expect(h.store.state.items[habit.id]?.deletedAt == local(2026, 11, 11, 12))
        #expect(h.store.state.items[habit.id]?.updatedAt == local(2026, 11, 11, 12))
        #expect(h.store.state.checkIns.count == 1)
        #expect(throws: ClewError.itemNotFound) { try h.clew.checkIn(itemId: habit.id) }
    }

    @Test func deletingTwiceKeepsTheFirstTime() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "x", shape: .later))
        try h.clew.deleteItem(itemId: item.id)
        h.clock.set(local(2026, 11, 11, 13))
        try h.clew.deleteItem(itemId: item.id)
        #expect(h.store.state.items[item.id]?.deletedAt == local(2026, 11, 11, 10))
        #expect(throws: ClewError.itemNotFound) { try h.clew.deleteItem(itemId: UUID()) }
    }
}

@Suite struct TitleOriginTests {
    @Test func fetchedTitleIsMarkedUntilTheUserChangesIt() throws {
        let h = Harness()
        let item = try h.clew.addItem(NewItem(title: "A talk", titleOrigin: .fetched,
                                              url: URL(string: "https://youtu.be/x"), shape: .later))
        #expect(item.titleOrigin == .fetched)
        let sameTitle = try h.clew.editItem(id: item.id, ItemEdit(title: "A talk", url: URL(string: "https://youtu.be/y")))
        #expect(sameTitle.titleOrigin == .fetched)
        let renamed = try h.clew.editItem(id: item.id, ItemEdit(title: "My talk", url: nil))
        #expect(renamed.titleOrigin == .typed)
        #expect(try h.clew.addItem(NewItem(title: "t", shape: .today)).titleOrigin == .typed)
    }
}

@Suite struct EditAndArchiveTests {
    @Test func editChangesTitleURLScheduleAndTarget() throws {
        let h = Harness()
        let goal = try h.clew.addItem(NewItem(title: "g", shape: .goal(target: 30, schedule: .daily)))
        h.clock.set(local(2026, 11, 11, 12))
        let edited = try h.clew.editItem(
            id: goal.id,
            ItemEdit(title: "ML course", url: URL(string: "https://course.example"),
                     schedule: .weekdays([.monday]), target: 40)
        )
        #expect(edited.title == "ML course")
        #expect(edited.url?.absoluteString == "https://course.example")
        #expect(edited.schedule == .weekdays([.monday]))
        #expect(edited.progress == .counter(target: 40))
        #expect(edited.updatedAt == local(2026, 11, 11, 12))
        #expect(edited.createdAt == goal.createdAt)
        #expect(h.store.state.items[goal.id] == edited)
    }

    @Test func editRejectsFieldsThatDoNotApplyToTheKind() throws {
        let h = Harness()
        let once = try h.clew.addItem(NewItem(title: "o", shape: .today))
        let habit = try h.clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        #expect(throws: ClewError.notAllowed) {
            try h.clew.editItem(id: once.id, ItemEdit(title: "o", url: nil, schedule: .daily))
        }
        #expect(throws: ClewError.invalidSchedule) {
            try h.clew.editItem(id: habit.id, ItemEdit(title: "h", url: nil, schedule: .daily, target: 3))
        }
        #expect(throws: ClewError.emptyTitle) {
            try h.clew.editItem(id: habit.id, ItemEdit(title: "", url: nil, schedule: .daily))
        }
        #expect(h.store.state.items[habit.id] == habit)
    }

    @Test func archivedItemsLeaveTodayButKeepTheirHistory() throws {
        let h = Harness()
        let habit = try h.clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        try h.clew.checkIn(itemId: habit.id)
        try h.clew.archive(itemId: habit.id)
        #expect(try h.clew.today().rows.isEmpty)
        #expect(h.store.state.checkIns.count == 1)
        #expect(h.store.state.items[habit.id]?.state == .archived)
    }
}
