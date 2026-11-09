import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

@Suite struct ReminderCommandTests {
    let store = FakeStore()
    let clock = TestClock(local(2026, 11, 11, 8))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    @Test func setUpdatesInPlaceAndNilTombstones() throws {
        let item = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        let first = try #require(try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 18, minute: 0)))
        clock.set(local(2026, 11, 11, 9))
        let second = try #require(try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 7, minute: 30)))
        #expect(second.id == first.id && second.time == TimeOfDay(hour: 7, minute: 30))
        #expect(second.updatedAt == local(2026, 11, 11, 9))
        #expect(try clew.reminder(forItem: item.id) == second)
        #expect(try clew.setReminder(itemId: item.id, time: nil) == nil)
        #expect(try clew.reminder(forItem: item.id) == nil)
        #expect(store.state.reminders[first.id]?.deletedAt == local(2026, 11, 11, 9))
        // A new one after removal is a new row; the old stays as a tombstone.
        let third = try #require(try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 20, minute: 0)))
        #expect(third.id != first.id && store.state.reminders.count == 2)
    }

    @Test func remindersNeedALiveItem() throws {
        #expect(throws: ClewError.itemNotFound) { try clew.setReminder(itemId: UUID(), time: TimeOfDay(hour: 9, minute: 0)) }
        let item = try clew.addItem(NewItem(title: "x", shape: .today))
        try clew.deleteItem(itemId: item.id)
        #expect(throws: ClewError.itemNotFound) { try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 9, minute: 0)) }
    }

    @Test func deletingAnItemRemovesItsReminder() throws {
        let item = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        let r = try #require(try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 18, minute: 0)))
        clock.set(local(2026, 11, 11, 9))
        try clew.deleteItem(itemId: item.id)
        #expect(store.state.reminders[r.id]?.deletedAt == local(2026, 11, 11, 9))
        #expect(try !clew.wantsNotifications())
    }

    @Test func aReminderOfAnArchivedItemDoesNotNeedNotifications() throws {
        let item = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 18, minute: 0))
        try clew.archive(itemId: item.id)
        #expect(try !clew.wantsNotifications())
    }

    @Test func itemLookupSkipsDeletedItems() throws {
        let item = try clew.addItem(NewItem(title: "l", url: URL(string: "https://a.example"), shape: .later))
        #expect(try clew.item(id: item.id)?.url?.absoluteString == "https://a.example")
        try clew.deleteItem(itemId: item.id)
        #expect(try clew.item(id: item.id) == nil)
    }

    @Test func summariesDefaultOffAndRoundTrip() throws {
        #expect(try clew.summaries() == .defaults)
        #expect(try !clew.wantsNotifications())
        var s = SummarySettings.defaults
        s.eveningEnabled = true
        s.eveningTime = TimeOfDay(hour: 22, minute: 15)!
        try clew.setSummaries(s)
        #expect(try clew.summaries() == s)
        #expect(try clew.wantsNotifications())
    }

    @Test func wantsNotificationsWhenAnyReminderExists() throws {
        let item = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 18, minute: 0))
        #expect(try clew.wantsNotifications())
        try clew.setReminder(itemId: item.id, time: nil)
        #expect(try !clew.wantsNotifications())
    }

    @Test func plannedNotificationsReflectTodaysTicks() throws {
        let item = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 18, minute: 0))
        #expect(try clew.plannedNotifications().first?.fireAt == local(2026, 11, 11, 18))
        try clew.checkIn(itemId: item.id)
        #expect(try clew.plannedNotifications().first?.fireAt == local(2026, 11, 12, 18))
    }
}
