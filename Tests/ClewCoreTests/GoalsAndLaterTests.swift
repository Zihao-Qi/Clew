import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

/// SPEC 2026-11-15, "Today and Goals & Later": moving between the lists for today only,
/// each list's order, ticking below, blocks and reminders of moved items.
@Suite struct GoalsAndLaterTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    func add(_ title: String, _ shape: NewItemShape) throws -> UUID { try clew.addItem(NewItem(title: title, shape: shape)).id }
    func today() throws -> [String] { try clew.today().rows.map(\.item.title) }
    func below() throws -> [String] { try clew.today().goalsAndLater.map(\.item.title) }
    func livePlans(_ id: UUID) -> [Plan] { store.state.plans.values.filter { $0.itemId == id && $0.voidedAt == nil } }

    @Test func movedToTodayForTodayOnlyThenBackAtItsOldPlace() throws {
        _ = try add("task", .today)
        _ = try add("first", .later)
        let goal = try add("goal", .goal(target: 30))
        _ = try add("last", .later)
        try clew.moveToToday(itemId: goal)
        #expect(try today() == ["task", "goal"] && below() == ["first", "last"])
        let item = try #require(store.state.items[goal])
        #expect(item.state == .active && item.schedule == .unscheduled)   // nothing else changed
        clock.set(at(11, 9))                                         // the next day
        #expect(try today() == ["task"] && below() == ["first", "goal", "last"])
    }

    @Test func movingBackUndoesTodaysMove() throws {
        let later = try add("later", .later)
        try clew.moveToToday(itemId: later)
        let block = try clew.placeOnTimeline(itemId: later, start: at(10, 11))
        try clew.moveBack(itemId: later)
        #expect(try today().isEmpty && below() == ["later"] && livePlans(later).isEmpty)
        #expect(store.state.timeBlocks[block.id]?.removedAt == at(10, 9))   // its block leaves with it
        #expect(throws: ClewError.notAllowed) { try clew.moveBack(itemId: later) }
    }

    @Test func reorderingAMovedRowReplacesItsPlan() throws {
        let a = try add("a", .today)
        let b = try add("b", .today)
        let later = try add("later", .later)
        try clew.moveToToday(itemId: later)                          // a, b, later
        let first = try #require(livePlans(later).first)
        try clew.place(itemId: later, in: .today, after: a, before: b)
        #expect(try today() == ["a", "later", "b"])
        // Plans are facts: the old one is voided and a new one placed (§4.2).
        #expect(store.state.plans[first.id]?.voidedAt != nil && livePlans(later).count == 1)
        // One of Today's own moves by its sort key, no plan.
        try clew.place(itemId: b, in: .today, after: nil, before: a)
        #expect(try today() == ["b", "a", "later"] && livePlans(b).isEmpty)
    }

    @Test func goalsAndLaterHasItsOwnOrder() throws {
        let one = try add("one", .later)
        let two = try add("two", .goal(target: 5))
        let three = try add("three", .later)
        try clew.place(itemId: three, in: .goalsAndLater, after: nil, before: one)
        #expect(try below() == ["three", "one", "two"])
        try clew.place(itemId: one, in: .goalsAndLater, after: two, before: nil)
        #expect(try below() == ["three", "two", "one"])
    }

    @Test func draggingAcrossTheLabel() throws {
        let a = try add("a", .today)
        let b = try add("b", .today)
        let habit = try add("habit", .habit(.daily))
        let x = try add("x", .later)
        let y = try add("y", .later)
        // Up into a gap of Today.
        try clew.place(itemId: y, in: .today, after: a, before: b)
        #expect(try today() == ["a", "y", "b", "habit"] && clew.today().moved == [y])
        // A once task of Today's own, with no tick, down into a gap: it is a Later item now.
        try clew.place(itemId: b, in: .goalsAndLater, after: nil, before: x)
        #expect(try below() == ["b", "x"] && store.state.items[b]?.state == .later
                && store.state.items[b]?.plannedDay == nil)
        // A moved row down: back below, where it was dropped.
        try clew.place(itemId: y, in: .goalsAndLater, after: b, before: x)
        #expect(try below() == ["b", "y", "x"] && clew.today().moved.isEmpty)
        // Habits stay on Today; a ticked once task too.
        #expect(throws: ClewError.notAllowed) { try clew.place(itemId: habit, in: .goalsAndLater, after: nil, before: nil) }
        try clew.checkIn(itemId: a)
        #expect(throws: ClewError.notAllowed) { try clew.place(itemId: a, in: .goalsAndLater, after: nil, before: nil) }
    }

    @Test func droppingAMovedRowBelowTakesItsBlocksOff() throws {
        let later = try add("later", .later)
        let block = try clew.placeOnTimeline(itemId: later, start: at(10, 11))
        try clew.place(itemId: later, in: .goalsAndLater, after: nil, before: nil)
        #expect(try store.state.timeBlocks[block.id]?.removedAt != nil && clew.today().moved.isEmpty)
    }

    @Test func twoRowsWithTheSameKeyStillTakeARowBetween() throws {
        let a = try add("a", .later)
        clock.set(at(10, 9, 1))
        let b = try add("b", .later)
        let c = try add("c", .later)
        // Same sort key for a and b (then ordered by creation: a first).
        try store.write { w in
            var item = try #require(try w.item(id: b))
            item.sortKey = try #require(try w.item(id: a)).sortKey
            try w.update(item)
        }
        try clew.place(itemId: c, in: .goalsAndLater, after: a, before: b)
        #expect(try below() == ["a", "c", "b"])
    }

    @Test func aReachedGoalCannotMoveUp() throws {
        let goal = try add("goal", .goal(target: 1))
        try clew.checkIn(itemId: goal)
        #expect(throws: ClewError.notAllowed) { try clew.moveToToday(itemId: goal) }
    }

    @Test func manyMovesIntoOneGapRenumberTheList() throws {
        let a = try add("a", .today)
        let b = try add("b", .today)
        let later = try add("later", .later)
        try clew.moveToToday(itemId: later)
        var above = a
        for i in 0..<60 {
            let id = try add("t\(i)", .today)
            try clew.place(itemId: id, in: .today, after: above, before: b)
            above = id
        }
        let titles = try today()
        #expect(titles.first == "a" && titles.dropLast().last == "b" && titles.last == "later" && titles.count == 63)
        #expect(Array(titles[1...60]) == (0..<60).map { "t\($0)" })
        // Below too.
        let x = try add("x", .later), y = try add("y", .later)
        var prev = x
        for i in 0..<60 {
            let id = try add("l\(i)", .later)
            try clew.place(itemId: id, in: .goalsAndLater, after: prev, before: y)
            prev = id
        }
        let rest = try below()
        #expect(rest.first == "x" && rest.last == "y" && rest.count == 62)
    }

    @Test func aMovedLaterItemTicksAndItsBlockTicksAtItsEnd() throws {
        let later = try add("later", .later)
        try clew.checkIn(itemId: later)                              // ticked below: counts, stays
        #expect(try clew.today().total == 1 && below() == ["later"])
        let other = try add("read", .later)
        try clew.placeOnTimeline(itemId: other, start: at(10, 10))   // dropped on an hour: moved up
        #expect(try today() == ["read"])
        clock.set(at(10, 10, 31)); try clew.settleBlocks()
        #expect(store.state.checkIns.values.contains { $0.itemId == other && $0.source == .timeline })
        // Asleep past the rollover: the late tick goes to its block's day.
        let late = try add("late", .later)
        try clew.placeOnTimeline(itemId: late, start: at(10, 22, 30))
        clock.set(at(11, 9)); try clew.settleBlocks()
        #expect(store.state.checkIns.values.contains { $0.itemId == late && $0.localDay == LocalDay(string: "2026-11-10")! })
    }

    @Test func movingToLaterGoesToTheEndAndOffTodaysTimeline() throws {
        // The task is older than the Later item, so only the move can put it last.
        let task = try add("task", .today)
        let one = try add("one", .later)
        let block = try clew.placeOnTimeline(itemId: task, start: at(10, 11))
        try clew.moveToLater(itemId: task)
        #expect(try below() == ["one", "task"] && today().isEmpty)
        #expect(store.state.timeBlocks[block.id]?.removedAt != nil)
        // On a moved item it moves it back.
        try clew.moveToToday(itemId: one)
        try clew.moveToLater(itemId: one)
        #expect(try clew.today().moved.isEmpty && below() == ["one", "task"])
    }

    @Test func remindersFireInBothLists() throws {
        let goal = try add("goal", .goal(target: 30))
        _ = try clew.setReminder(itemId: goal, time: TimeOfDay(hour: 18, minute: 0)!)
        let reminders = try clew.plannedNotifications().filter { if case .reminder = $0.content { true } else { false } }
        #expect(reminders.first?.fireAt == at(10, 18))
        // Done today: none today.
        try clew.checkIn(itemId: goal)
        let after = try clew.plannedNotifications().filter { if case .reminder = $0.content { true } else { false } }
        #expect(after.first?.fireAt == at(11, 18))
    }
}
