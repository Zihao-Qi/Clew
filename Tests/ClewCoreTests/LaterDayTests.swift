import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}
private func day(_ d: Int) -> LocalDay { LocalDay(year: 2026, month: 11, day: d)! }

/// SPEC 2026-11-17, "A day for Later": a plan booked ahead; on its day the task is on
/// Today for that day only; quiet reminders while it waits. Tuesday Nov 10, 09:00.
@Suite struct LaterDayTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    func add(_ title: String, _ shape: NewItemShape, day: LocalDay? = nil) throws -> UUID {
        try clew.addItem(NewItem(title: title, shape: shape, laterDay: day)).id
    }
    func today() throws -> [String] { try clew.today().rows.map(\.item.title) }
    func below() throws -> [String] { try clew.today().goalsAndLater.map(\.item.title) }
    func livePlans(_ id: UUID) -> [Plan] { store.state.plans.values.filter { $0.itemId == id && $0.voidedAt == nil } }

    @Test func waitsThenTodayForThatDayOnlyThenBackWithNoDay() throws {
        _ = try add("task", .today)
        let call = try add("call", .later, day: day(12))
        _ = try add("other", .later)
        #expect(try today() == ["task"] && below() == ["call", "other"])
        #expect(try clew.today().waiting == [call: day(12)] && clew.laterDay(itemId: call) == day(12))
        clock.set(at(11, 9))                                            // still waiting
        #expect(try today() == ["task"] && clew.today().waiting[call] == day(12))
        clock.set(at(12, 9))                                            // its day
        #expect(try today() == ["task", "call"] && below() == ["other"] && clew.today().moved == [call])
        #expect(try clew.laterDay(itemId: call) == nil)                // its day is today: not waiting
        #expect(try clew.today().total == 2)                            // it counts
        clock.set(at(13, 9))                                            // not ticked: back, no day
        #expect(try today() == ["task"] && below() == ["call", "other"] && clew.today().waiting.isEmpty)
    }

    @Test func aDayMustBeAfterTodayAndOnlyForLater() throws {
        #expect(throws: ClewError.notAllowed) { try add("a", .later, day: day(10)) }
        #expect(throws: ClewError.notAllowed) { try add("past", .later, day: day(9)) }
        #expect(throws: ClewError.notAllowed) { try add("b", .today, day: day(12)) }
        // Before 4 a.m. the Clew day is still yesterday: "tomorrow" is the coming morning.
        clock.set(at(11, 2))
        let c = try add("c", .later, day: day(11))
        #expect(try clew.today().waiting[c] == day(11))
    }

    @Test func givingADayToEachKindOfRow() throws {
        let own = try add("own", .today)
        let moved = try add("moved", .later)
        let waiting = try add("waiting", .later)
        let habit = try add("habit", .habit(.daily))
        let goal = try add("goal", .goal(target: 9))
        let ticked = try add("ticked", .today)
        try clew.moveToToday(itemId: moved)
        let block = try clew.placeOnTimeline(itemId: own, start: at(10, 11))
        let movedBlock = try clew.placeOnTimeline(itemId: moved, start: at(10, 12))
        try clew.checkIn(itemId: ticked)
        #expect(try today() == ["own", "habit", "ticked", "moved"] && below() == ["waiting", "goal"])

        // Today's own: to Later at Goals & Later's end, its blocks off the timeline.
        try clew.setLaterDay(itemId: own, day: day(13))
        let item = try #require(store.state.items[own])
        #expect(item.state == .later && item.plannedDay == nil)
        #expect(try below().last == "own" && clew.today().waiting[own] == day(13))
        #expect(store.state.timeBlocks[block.id]?.removedAt == at(10, 9))
        // A moved row goes back down to its place first.
        try clew.setLaterDay(itemId: moved, day: day(12))
        #expect(try today() == ["habit", "ticked"] && clew.today().moved.isEmpty)
        #expect(store.state.timeBlocks[movedBlock.id]?.removedAt == at(10, 9))   // its blocks too
        // One in Goals & Later keeps its place; choosing another day replaces it.
        try clew.setLaterDay(itemId: waiting, day: day(20))
        let before = try below()
        try clew.setLaterDay(itemId: waiting, day: day(14))
        #expect(try below() == before && livePlans(waiting).map(\.localDay) == [day(14)])
        // No day: a plain Later task.
        try clew.setLaterDay(itemId: waiting, day: nil)
        #expect(try livePlans(waiting).isEmpty && clew.today().waiting[waiting] == nil)
        // Not habits, goals or ticked tasks; not today.
        for id in [habit, goal, ticked] {
            #expect(throws: ClewError.notAllowed) { try clew.setLaterDay(itemId: id, day: day(12)) }
        }
        #expect(throws: ClewError.notAllowed) { try clew.setLaterDay(itemId: waiting, day: day(10)) }
        #expect(throws: ClewError.notAllowed) { try clew.setLaterDay(itemId: waiting, day: day(9)) }
        // A saved link can wait too; a YouTube or X item never.
        let link = try clew.addItem(NewItem(title: "article", url: URL(string: "https://medium.com/a"), shape: .later))
        #expect(link.kind == .link)
        try clew.setLaterDay(itemId: link.id, day: day(12))
        #expect(try clew.today().waiting[link.id] == day(12))
        let video = Item(id: UUID(), kind: .link, title: "video", schedule: .unscheduled, progress: .none, state: .later,
                         sortKey: 1, source: .extensionYouTube, createdAt: at(10, 9), updatedAt: at(10, 9))
        #expect(!Clew.canHaveDay(TodayRow(item: video, state: .due, todayAmount: 0, progressAmount: 0, lastTickToday: nil)))
    }

    @Test func movedEarlyItsDayIsDropped() throws {
        let a = try add("a", .later, day: day(13))
        let b = try add("b", .later, day: day(13))
        try clew.moveToToday(itemId: a)
        _ = try clew.placeOnTimeline(itemId: b, start: at(10, 11))     // onto an hour
        #expect(try today() == ["a", "b"] && clew.today().waiting.isEmpty)
        #expect(livePlans(a).map(\.localDay) == [day(10)] && livePlans(b).map(\.localDay) == [day(10)])
        clock.set(at(13, 9))                                            // its old day: nothing
        #expect(try today().isEmpty && below() == ["a", "b"])
    }

    @Test func movedBackDownOnItsDayKeepsNothing() throws {
        let a = try add("a", .later, day: day(12))
        clock.set(at(12, 9))
        try clew.moveBack(itemId: a)
        #expect(try today().isEmpty && below() == ["a"] && clew.today().waiting.isEmpty)
    }

    @Test func onItsDayItGoesToTodaysEndInTheOrderDaysWereSet() throws {
        let late = try add("late", .later)                             // older sort key
        let early = try add("early", .later)
        _ = try add("task", .today)
        try clew.setLaterDay(itemId: early, day: day(12))
        clock.set(at(10, 10))
        try clew.setLaterDay(itemId: late, day: day(12))
        clock.set(at(12, 9))
        _ = try add("added", .today)                                    // before the refresh
        #expect(try clew.settlePlans())
        #expect(try today() == ["task", "added", "early", "late"])
        #expect(try !clew.settlePlans())                                 // once
        // Dragging it like any moved row works, and a new task still goes after it.
        let list = try clew.today()
        try clew.place(itemId: late, in: .today, after: nil, before: list.rows[0].id)
        _ = try add("newest", .today)
        #expect(try today() == ["late", "task", "added", "early", "newest"])
    }

    /// A goal's nil-key plan (as the v11 migration made) keeps the item's own key; a
    /// Later task's is settled whenever it was recorded (a time-zone change can make a
    /// plan booked the evening before look recorded after its day began).
    @Test func onlyALaterTasksNilKeyPlanIsSettled() throws {
        let g = try add("goal", .goal(target: 9))
        let l = try add("later", .later)
        try store.write { w in
            try w.insert(Plan(id: UUID(), itemId: g, localDay: day(10), at: at(10, 5), source: .user, todaySortKey: nil))
        }
        #expect(try !clew.settlePlans())
        try store.write { w in
            try w.insert(Plan(id: UUID(), itemId: l, localDay: day(10), at: at(10, 6), source: .user, todaySortKey: nil))
        }
        #expect(try clew.settlePlans())
        #expect(livePlans(l).first?.todaySortKey != nil && livePlans(g).first?.todaySortKey == nil)
    }

    @Test func tickedWhileWaitingItIsDoneAndNeverArrives() throws {
        let a = try add("a", .later, day: day(12))
        try clew.checkIn(itemId: a)
        #expect(try below() == ["a"] && clew.today().waiting.isEmpty)    // done: no day shown
        #expect(try clew.details(itemId: a)?.waitingFor == nil)
        clock.set(at(12, 9))
        #expect(try today().isEmpty && below().isEmpty && !clew.settlePlans())
        // Its day never came: no "Moved to Today" line.
        #expect(try #require(try clew.details(itemId: a)).history.allSatisfy { $0.event != .picked })
    }

    @Test func labelsAndNextMonday() {
        let tue = day(10)
        #expect(DayLabel(day(11), today: tue) == .tomorrow)
        #expect(DayLabel(day(12), today: tue) == .weekday(day(12)))
        #expect(DayLabel(day(16), today: tue) == .weekday(day(16)))
        #expect(DayLabel(day(17), today: tue) == .date(day(17)))
        #expect(Clew.nextMonday(after: tue) == day(16))
        #expect(Clew.nextMonday(after: day(16)) == day(23))              // from a Monday: a week on
        #expect(Clew.nextMonday(after: day(15)) == day(16))              // from Sunday: tomorrow
    }

    @Test func remindersAreQuietWhileItWaits() throws {
        let a = try add("a", .later, day: day(12))
        let six = TimeOfDay(hour: 18, minute: 0)!
        try clew.setReminder(itemId: a, time: six)
        func fires() throws -> [Date] {
            try clew.plannedNotifications().filter { if case .reminder = $0.content { true } else { false } }.map(\.fireAt)
        }
        // Not Tue or Wed; Thursday (on Today) and after (back in Later) as any task.
        #expect(try fires().prefix(3) == [at(12, 18), at(13, 18), at(14, 18)])
        // A Today reminder was asked for today: it fires.
        try clew.setReminder(itemId: a, time: six, todayOnly: true)
        #expect(try fires() == [at(10, 18)])
    }

    @Test func theDaysAheadCountItOnToday() throws {
        _ = try add("a", .later, day: day(12))
        try clew.setSummaries(SummarySettings(morningEnabled: true, morningTime: TimeOfDay(hour: 9, minute: 30)!,
                                              eveningEnabled: false, eveningTime: TimeOfDay(hour: 21, minute: 0)!))
        let mornings = try clew.plannedNotifications().compactMap { n -> Date? in
            if case .morning = n.content { n.fireAt } else { nil }
        }
        #expect(mornings == [at(12, 9, 30)])                            // nothing on Today otherwise
    }

    @Test func historyListsADayOnlyOnceItCame() throws {
        let a = try add("a", .later, day: day(12))
        let b = try add("b", .later, day: day(12))
        func picked(_ id: UUID) throws -> [Date] {
            try #require(try clew.details(itemId: id)).history.compactMap { $0.event == .picked ? $0.at : nil }
        }
        #expect(try picked(a).isEmpty && clew.details(itemId: a)?.waitingFor == day(12))
        try clew.setLaterDay(itemId: b, day: nil)                        // removed before it came
        clock.set(at(12, 9))
        #expect(try picked(a) == [at(12, 4)] && picked(b).isEmpty)       // dated by its day
        #expect(try clew.details(itemId: a)?.waitingFor == nil)
    }
}
