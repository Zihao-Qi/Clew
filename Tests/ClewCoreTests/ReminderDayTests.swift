import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

/// SPEC 2026-11-15, "Today or every day": a reminder fires today only, or every day.
@Suite struct ReminderDayTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }
    let six = TimeOfDay(hour: 18, minute: 0)!

    func reminders() throws -> [Date] {
        try clew.plannedNotifications().filter { if case .reminder = $0.content { true } else { false } }.map(\.fireAt)
    }

    @Test func everyDayIsTheDefaultAndFiresEachDay() throws {
        let id = try clew.addItem(NewItem(title: "goal", shape: .goal(target: 30))).id
        let r = try #require(try clew.setReminder(itemId: id, time: six))
        #expect(r.day == nil)
        #expect(try reminders().prefix(2) == [at(10, 18), at(11, 18)])
    }

    @Test func todayFiresOnceThenIsSpent() throws {
        let id = try clew.addItem(NewItem(title: "task", shape: .later)).id
        let r = try #require(try clew.setReminder(itemId: id, time: six, todayOnly: true))
        #expect(r.day == LocalDay(string: "2026-11-10")!)
        #expect(try reminders() == [at(10, 18)])
        #expect(try clew.wantsNotifications())
        #expect(try clew.details(itemId: id)?.reminder?.day != nil)
        // The next day it is spent: off everywhere.
        clock.set(at(11, 9))
        #expect(try reminders().isEmpty && clew.reminder(forItem: id) == nil)
        #expect(try clew.details(itemId: id)?.reminder == nil && !clew.wantsNotifications())
    }

    @Test func todayAtAPassedTimeIsRefusedAndNothingChanges() throws {
        let id = try clew.addItem(NewItem(title: "task", shape: .today)).id
        try clew.setReminder(itemId: id, time: six)                       // every day, 18:00
        #expect(throws: ClewError.reminderTimePassed) {
            try clew.setReminder(itemId: id, time: TimeOfDay(hour: 8, minute: 0)!, todayOnly: true)
        }
        #expect(try clew.reminder(forItem: id)?.time == six && clew.reminder(forItem: id)?.day == nil)
        // Every day at a passed time is fine: it fires tomorrow.
        try clew.setReminder(itemId: id, time: TimeOfDay(hour: 8, minute: 0)!)
        #expect(try reminders().first == at(11, 8))
        // Between midnight and 4 a.m. the Clew day is still yesterday: a morning time is past.
        clock.set(at(11, 1))
        #expect(clew.isPastToday(TimeOfDay(hour: 9, minute: 0)!))
        #expect(!clew.isPastToday(TimeOfDay(hour: 2, minute: 0)!))
    }

    @Test func switchingBetweenTodayAndEveryDay() throws {
        let id = try clew.addItem(NewItem(title: "task", shape: .later)).id
        try clew.setReminder(itemId: id, time: six, todayOnly: true)
        try clew.setReminder(itemId: id, time: six)                       // back to every day
        #expect(try clew.reminder(forItem: id)?.day == nil && reminders().count > 1)
        // One live reminder per item, whatever the choice.
        #expect(store.state.reminders.values.filter { $0.itemId == id && $0.deletedAt == nil }.count == 1)
    }

    @Test func aSpentReminderCanBeSetAgainLater() throws {
        let id = try clew.addItem(NewItem(title: "task", shape: .later)).id
        try clew.setReminder(itemId: id, time: six, todayOnly: true)
        clock.set(at(12, 9))                                              // two days on: spent
        #expect(try clew.reminder(forItem: id) == nil)
        let again = try #require(try clew.setReminder(itemId: id, time: six, todayOnly: true))
        #expect(try again.day == LocalDay(string: "2026-11-12")! && reminders() == [at(12, 18)])
        // Still one row for the item.
        #expect(store.state.reminders.values.filter { $0.itemId == id && $0.deletedAt == nil }.count == 1)
    }

    /// An export from before 2026-11-15 has reminders without "day": every day.
    @Test func anOlderExportsReminderIsEveryDay() throws {
        let json = """
            {"id":"00000000-0000-0000-0000-000000000001","itemId":"00000000-0000-0000-0000-000000000002",
             "time":{"hour":18,"minute":0},"enabled":true,"updatedAt":0}
            """
        let r = try JSONDecoder().decode(Reminder.self, from: Data(json.utf8))
        #expect(r.day == nil && r.fires(on: LocalDay(string: "2026-11-10")!))
    }
}
