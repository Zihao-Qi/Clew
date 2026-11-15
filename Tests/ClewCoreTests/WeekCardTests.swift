import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

/// SPEC 2026-11-15, "Last week's card": which week, shown once, the switch, deletions.
/// November 2026: Monday the 9th to Sunday the 15th is "last week" from the 16th on.
@Suite struct WeekCardTests {
    let store = FakeStore()
    let clock = TestClock(local(12, 10))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    @Test func lastWeekIsTheMondayToSundayBeforeThisWeek() throws {
        let id = try clew.addItem(NewItem(title: "write", shape: .today)).id
        _ = try clew.checkIn(itemId: id)                          // Thursday the 12th
        #expect(try clew.weekCard() == nil)                       // still this week
        clock.set(local(16, 3, 59))                               // Monday before 4 a.m.: still Sunday
        #expect(try clew.weekCard() == nil)
        clock.set(local(16, 4))
        let card = try #require(try clew.weekCard())
        #expect(card.weekStart == LocalDay(string: "2026-11-09")! && card.done == 1)
        #expect(try clew.lastWeek() == card)
        // Weeks later, last week is the one just before: empty, so no card.
        clock.set(local(30, 10))
        #expect(try clew.weekCard() == nil && clew.lastWeek() == nil)
    }

    @Test func aTickAtOneOnMondayBelongsToSundaysWeek() throws {
        let id = try clew.addItem(NewItem(title: "late", shape: .today)).id
        clock.set(local(16, 1))
        _ = try clew.checkIn(itemId: id)                          // Clew day: Sunday the 15th
        clock.set(local(16, 9))
        #expect(try clew.weekCard()?.done == 1)
    }

    @Test func shownOnceThenOnlyInSettingsAndAClockSetBackDoesNotHideOtherWeeks() throws {
        let id = try clew.addItem(NewItem(title: "write", shape: .today)).id
        _ = try clew.checkIn(itemId: id)
        clock.set(local(16, 9))
        let card = try #require(try clew.weekCard())
        try clew.markWeekCardShown(card)
        #expect(try clew.weekCard() == nil)
        #expect(try clew.lastWeek() == card)                      // Settings › Progress still has it
        // The clock goes back into the week before: that week's own card is not hidden.
        let other = try clew.addItem(NewItem(title: "earlier", shape: .today)).id
        clock.set(local(5, 10)); _ = try clew.checkIn(itemId: other)
        clock.set(local(10, 10))
        #expect(try clew.weekCard()?.weekStart == LocalDay(string: "2026-11-02")!)
    }

    @Test func theSwitchTurnsOffOnlyTheMenuCard() throws {
        let id = try clew.addItem(NewItem(title: "write", shape: .today)).id
        _ = try clew.checkIn(itemId: id)
        clock.set(local(16, 9))
        #expect(try clew.weekCardOn())                            // on by default
        try clew.setWeekCardOn(false)
        #expect(try clew.weekCard() == nil && clew.lastWeek() != nil)
        try clew.setWeekCardOn(true)
        #expect(try clew.weekCard() != nil)                       // not shown yet: back
    }

    @Test func aVideoThatLeftWatchLaterCountsAndOneTheUserDeletedDoesNot() throws {
        func batch(_ refs: [String]) -> ImportBatch {
            ImportBatch(source: .extensionYouTube, entries: refs.map { ExternalEntry(externalRef: $0, title: "v") },
                        listTotal: refs.count, scan: ScanReport(found: refs.count, parsed: refs.count, selectorVersion: "t"))
        }
        try clew.importExternal(batch(["aaaaaaaaaaa", "bbbbbbbbbbb"]))
        // The first leaves Watch Later: counted finished (ticked and removed together).
        let r = try clew.importExternal(batch(["bbbbbbbbbbb"]))
        #expect(r.letGo == 1)
        let videos = try store.read { try $0.items(source: .extensionYouTube) }
        let deleted = try #require(videos.first { $0.externalRef == "bbbbbbbbbbb" })
        _ = try clew.checkIn(itemId: deleted.id)
        try clew.deleteItem(itemId: deleted.id)
        clock.set(local(16, 9))
        let card = try #require(try clew.weekCard())
        #expect(card.watched == 1 && card.done == 0)
    }
}
