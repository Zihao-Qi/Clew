import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ d: Int, _ h: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
}

@Suite struct DetailsTests {
    @Test func detailsGatherStatsRoundsAndReminder() throws {
        let store = FakeStore()
        let clock = TestClock(local(2, 10))
        let clew = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
        let goal = try clew.addItem(NewItem(title: "g", shape: .goal(target: 2, schedule: .daily)))
        try clew.checkIn(itemId: goal.id)
        clock.set(local(9, 10))
        try clew.checkIn(itemId: goal.id)           // round 1 reached on Nov 9
        clock.set(local(9, 10).addingTimeInterval(60))
        try clew.startNextRound(itemId: goal.id)    // a minute later
        clock.set(local(11, 10))
        try clew.checkIn(itemId: goal.id)           // round 2: 1/2
        try clew.setReminder(itemId: goal.id, time: TimeOfDay(hour: 18, minute: 0))

        let d = try #require(try clew.details(itemId: goal.id))
        #expect(d.today == LocalDay(string: "2026-11-11"))
        #expect(d.progressAmount == 1)
        #expect(d.stats.roundsFinished == 1)
        #expect(d.stats.totalAmount == 3)
        #expect(d.stats.daysAllTime == 3 && d.stats.daysThisWeek == 2 && d.stats.daysLast30 == 3)
        #expect(d.reminder?.time == TimeOfDay(hour: 18, minute: 0))
    }

    @Test func deletedOrUnknownItemsHaveNoDetails() throws {
        let store = FakeStore()
        let clew = Clew(store: store, clock: TestClock(local(11, 10)), zones: FixedZone("America/New_York"))
        let item = try clew.addItem(NewItem(title: "x", shape: .today))
        try clew.deleteItem(itemId: item.id)
        #expect(try clew.details(itemId: item.id) == nil)
        #expect(try clew.details(itemId: UUID()) == nil)
    }
}
