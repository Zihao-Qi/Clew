import ClewCore
import ClewDomain
import Foundation
import Testing

@Suite struct RatingTests {
    let store = FakeStore()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("UTC")) }

    @Test func offByDefaultAndSwitchable() throws {
        #expect(try !clew.ratingsEnabled())
        try clew.setRatingsEnabled(true)
        #expect(try clew.ratingsEnabled())
        try clew.setRatingsEnabled(false)
        #expect(try !clew.ratingsEnabled())
    }

    @Test func aRatingIsStoredAndTheLatestWins() throws {
        let item = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        let tick = try clew.checkIn(itemId: item.id)
        try clew.rate(checkInId: tick.id, rating: 3)
        clock.set(Date(timeIntervalSince1970: 1_800_000_060))
        try clew.rate(checkInId: tick.id, rating: 2)
        let stored = try #require(store.state.checkIns[tick.id])
        #expect(stored.rating == 2 && stored.ratedAt == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(stored.amount == 1 && stored.localDay == tick.localDay)  // nothing else changed
    }

    @Test func onlyOneToFiveOnALiveTick() throws {
        let item = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        let tick = try clew.checkIn(itemId: item.id)
        #expect(throws: ClewError.notAllowed) { try clew.rate(checkInId: tick.id, rating: 0) }
        #expect(throws: ClewError.notAllowed) { try clew.rate(checkInId: tick.id, rating: 6) }
        try clew.rate(checkInId: tick.id, rating: 5)
        try clew.rate(checkInId: tick.id, rating: 1)
        #expect(store.state.checkIns[tick.id]?.rating == 1)
        #expect(throws: ClewError.checkInNotFound) { try clew.rate(checkInId: UUID(), rating: 2) }
        try clew.undoToday(itemId: item.id)
        #expect(throws: ClewError.notAllowed) { try clew.rate(checkInId: tick.id, rating: 2) }
        #expect(store.state.checkIns[tick.id]?.rating == 1)        // the voided tick keeps its last rating
    }

    @Test func detailsCountHowRatedTicksFelt() throws {
        let item = try clew.addItem(NewItem(title: "g", shape: .goal(target: 99, schedule: .daily)))
        let ticks = try (0..<4).map { i in
            clock.set(Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60)) // one minute apart
            return try clew.checkIn(itemId: item.id)
        }
        try clew.rate(checkInId: ticks[0].id, rating: 3)
        try clew.rate(checkInId: ticks[1].id, rating: 3)
        try clew.rate(checkInId: ticks[2].id, rating: 1)
        try clew.rate(checkInId: ticks[3].id, rating: 1)
        try clew.undoToday(itemId: item.id)                 // voids ticks[3]: its rating no longer counts
        try clew.rate(checkInId: ticks[2].id, rating: 2)    // re-rated
        let felt = try #require(try clew.details(itemId: item.id)).stats.feltCounts
        #expect(felt == [3: 2, 2: 1])
    }
}
