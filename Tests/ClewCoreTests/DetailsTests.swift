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

    @Test func aOneOffItemHasAHistoryInsteadOfAHeatmap() throws {
        let store = FakeStore()
        let clock = TestClock(local(3, 10))
        let clew = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
        try clew.setRatingsEnabled(true)
        let link = try clew.addItem(NewItem(title: "v", url: URL(string: "https://example.com/v"), shape: .later))
        clock.set(local(5, 10)); try clew.keepLater(itemId: link.id)
        clock.set(local(9, 10)); try clew.planForToday(itemIds: [link.id])
        clock.set(local(9, 12)); let tick = try clew.checkIn(itemId: link.id)
        try clew.rate(checkInId: tick.id, rating: 4)

        let d = try #require(try clew.details(itemId: link.id))
        #expect(d.isOneOff)
        #expect(d.history.map(\.event) == [.added(.user), .kept, .picked, .done(rating: 4)])
        #expect(d.history.map(\.at) == [local(3, 10), local(5, 10), local(9, 10), local(9, 12)])
    }

    @Test func historyIsTheLatestLinesWithoutUndoneTicks() throws {
        let store = FakeStore()
        let clock = TestClock(local(1, 10))
        let clew = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
        let link = try clew.addItem(NewItem(title: "v", url: URL(string: "https://example.com/v"), shape: .later))
        for day in 2...8 { clock.set(local(day, 10)); try clew.keepLater(itemId: link.id) }
        clock.set(local(9, 10)); try clew.planForToday(itemIds: [link.id])
        try clew.checkIn(itemId: link.id)
        try clew.undoToday(itemId: link.id)

        let history = try #require(try clew.details(itemId: link.id)).history
        #expect(history.count == Clew.historyLength)
        #expect(history.last == HistoryEntry(at: local(9, 10), event: .picked))   // the undone tick is gone
        #expect(history.first == HistoryEntry(at: local(4, 10), event: .kept))    // oldest lines dropped
    }

    @Test func habitsKeepTheHeatmapAndVideosShowWhatWasWatched() throws {
        let store = FakeStore()
        let clew = Clew(store: store, clock: TestClock(local(9, 10)), zones: FixedZone("America/New_York"))
        let habit = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        try clew.checkIn(itemId: habit.id)
        let h = try #require(try clew.details(itemId: habit.id))
        #expect(!h.isOneOff && h.history.isEmpty)
        let once = try clew.addItem(NewItem(title: "o", shape: .today))
        let o = try #require(try clew.details(itemId: once.id))
        #expect(o.isOneOff && o.history.first?.event == .added(.user))
        try clew.checkIn(itemId: once.id)
        #expect(try clew.details(itemId: once.id)?.history.last?.event == .done(rating: nil))   // not rated

        try clew.importExternal(ImportBatch(source: .extensionYouTube,
                                            entries: [ExternalEntry(externalRef: "aaaaaaaaaaa", title: "v", progress: 0.4)],
                                            listTotal: 1))
        let video = try #require(store.state.items.values.first { $0.externalRef == "aaaaaaaaaaa" })
        let v = try #require(try clew.details(itemId: video.id))
        #expect(v.isOneOff && v.watch?.fraction == 0.4 && v.history.map(\.event) == [.added(.extensionYouTube)])
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
