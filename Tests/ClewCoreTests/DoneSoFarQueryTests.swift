import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
}
private func day(_ d: Int) -> LocalDay { LocalDay(year: 2026, month: 11, day: d)! }

/// SPEC 2026-11-18, "Done so far" and a goal's Bars or Heatmap, read from the store.
@Suite struct DoneSoFarQueryTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    @Test func readsEveryDayDoneDeletedItemsIncluded() throws {
        let book = try clew.addItem(NewItem(title: "book", shape: .goal(target: 3)))
        let task = try clew.addItem(NewItem(title: "task", shape: .today))
        let gone = try clew.addItem(NewItem(title: "gone", shape: .habit(.daily)))
        try clew.checkIn(itemId: book.id); try clew.checkIn(itemId: book.id)
        try clew.checkIn(itemId: gone.id)
        clock.set(at(11, 9))
        try clew.checkIn(itemId: book.id)                                   // reached on the 11th
        try clew.checkIn(itemId: task.id)
        try clew.deleteItem(itemId: gone.id)
        let done = try clew.doneSoFar()
        #expect(done.perDay == [day(10): 2, day(11): 2])                    // book once a day; gone still counts
        #expect(done.goalReached == [day(11)])
        #expect(done.total(through: day(11)) == 4)
        // A goal deleted since keeps its dot, as its ticks keep counting.
        try clew.deleteItem(itemId: book.id)
        #expect(try clew.doneSoFar().goalReached == [day(11)])
    }

    @Test func choicesAreRememberedWithDefaults() throws {
        #expect(try clew.progressRange() == .all && clew.goalChart() == .bars)
        try clew.setProgressRange(.days30)
        try clew.setGoalChart(.heatmap)
        #expect(try clew.progressRange() == .days30 && clew.goalChart() == .heatmap)
    }
}
