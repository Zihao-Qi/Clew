import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ m: Int, _ d: Int, _ h: Int = 10) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
}

@Suite struct LaterReviewTests {
    let store = FakeStore()
    let clock = TestClock(local(9, 28))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    @Test func asksAfterSixWeeksUntouched() throws {
        let item = try clew.addItem(NewItem(title: "old", shape: .later))   // Sep 28
        clock.set(local(11, 8))                                              // 41 days
        #expect(try clew.laterPile().first?.asksStillWant == false)
        #expect(try clew.laterPile().first?.daysWaiting == 41)
        clock.set(local(11, 9))                                              // 42 days
        #expect(try clew.laterPile().map(\.id) == [item.id])
        #expect(try clew.laterPile().first?.asksStillWant == true)
        // 1 a.m. still belongs to the day before (rollover).
        clock.set(local(11, 9, 1))
        #expect(try clew.laterPile().first?.daysWaiting == 41)
    }

    @Test func anItemSavedAtOneAmBelongsToThePreviousDay() throws {
        clock.set(local(9, 28, 1))                       // 1 a.m. Sep 28 = still Sep 27
        _ = try clew.addItem(NewItem(title: "late night", shape: .later))
        clock.set(local(11, 8))                          // Sep 27 → Nov 8 is 42 days
        #expect(try clew.laterPile().first?.daysWaiting == 42)
    }

    @Test func editingOrKeepingStartsTheSixWeeksAgain() throws {
        let item = try clew.addItem(NewItem(title: "old", shape: .later))
        clock.set(local(11, 9))
        try clew.keepLater(itemId: item.id)
        #expect(try clew.laterPile().first?.daysWaiting == 0)
        clock.set(local(11, 20))
        try clew.editItem(id: item.id, ItemEdit(title: "renamed", url: nil))
        clock.set(local(11, 25))
        #expect(try clew.laterPile().first?.daysWaiting == 5)
        #expect(store.state.laterReviews.values.map(\.decision) == [.keep])
    }

    @Test func lettingGoRemovesTheItemAndCountsAsAWin() throws {
        let item = try clew.addItem(NewItem(title: "old", url: URL(string: "https://a.example"), shape: .later))
        try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 9, minute: 0))
        clock.set(local(11, 9))
        try clew.letGo(itemId: item.id)
        #expect(try clew.laterPile().isEmpty)
        #expect(try clew.lettingGoCount() == 1)
        #expect(store.state.items[item.id]?.deletedAt == local(11, 9))
        #expect(store.state.reminders.values.allSatisfy { $0.deletedAt == local(11, 9) })
        let review = try #require(store.state.laterReviews.values.first)
        #expect(review.decision == .letGo && review.localDay == LocalDay(string: "2026-11-09") && review.source == .user)
    }

    /// Reordering Today (even a full renumber) never restarts a Later item's 6 weeks.
    @Test func reorderingTodayLeavesLaterItemsUntouched() throws {
        let a = try clew.addItem(NewItem(title: "a", shape: .habit(.daily)))
        let b = try clew.addItem(NewItem(title: "b", shape: .habit(.daily)))
        // Saved after a and b, so a full renumber would have to change its sort key.
        let waiting = try clew.addItem(NewItem(title: "waiting", shape: .later))
        clock.set(local(11, 9))
        var below = b.id
        for i in 0..<60 {                                  // enough to force a renumber
            let x = try clew.addItem(NewItem(title: "x\(i)", shape: .habit(.daily)))
            try clew.moveItem(id: x.id, after: a.id, before: below)
            below = x.id
        }
        #expect(store.state.items[waiting.id]?.updatedAt == local(9, 28))
        #expect(try clew.laterPile().first?.asksStillWant == true)
    }

    @Test func onlyLaterItemsCanBeReviewed() throws {
        let today = try clew.addItem(NewItem(title: "t", shape: .today))
        #expect(throws: ClewError.notAllowed) { try clew.keepLater(itemId: today.id) }
        #expect(throws: ClewError.notAllowed) { try clew.letGo(itemId: today.id) }
        #expect(throws: ClewError.itemNotFound) { try clew.letGo(itemId: UUID()) }
        #expect(store.state.laterReviews.isEmpty)
        #expect(store.state.items[today.id]?.deletedAt == nil)
    }
}
