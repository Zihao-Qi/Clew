import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ d: Int, _ h: Int = 10) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
}

private func video(_ ref: String, watched: Double? = nil) -> ExternalEntry {
    ExternalEntry(externalRef: ref, title: "v \(ref)", progress: watched)
}

/// SPEC decision 2026-11-09: Watch Later is one collection below the tasks, with its
/// own page; its videos are ticked there and never count toward today.
@Suite struct CollectionTests {
    let store = FakeStore()
    let clock = TestClock(local(2))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    private func load(_ entries: [ExternalEntry]) throws {
        try clew.importExternal(ImportBatch(source: .extensionYouTube, entries: entries, listTotal: entries.count,
            scan: ScanReport(found: entries.count, parsed: entries.count, selectorVersion: "t")))
    }
    private func id(_ ref: String) throws -> UUID {
        try #require(store.state.items.values.first { $0.externalRef == ref }).id
    }

    @Test func noCollectionUntilSomethingIsImported() throws {
        #expect(try clew.collections().isEmpty)
        try clew.addItem(NewItem(title: "mine", url: URL(string: "https://www.youtube.com/watch?v=x"), shape: .later))
        #expect(try clew.collections().isEmpty)                    // the user's own links stay in Later
        #expect(try clew.collection(.user) == nil)
    }

    @Test func theRowCountsWhatIsOnTheListAndWhatIsDone() throws {
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb"), video("ccccccccccc"), video("ddddddddddd")])
        try clew.checkIn(itemId: try id("bbbbbbbbbbb"))
        let row = try #require(try clew.collections().first)
        #expect(row.source == .extensionYouTube && row.total == 4 && row.done == 1 && row.fraction == 0.25)
        #expect(try clew.today().total == 0)                        // never counted toward today
    }

    @Test func thePageGroupsAndOrdersTheList() throws {
        try load([video("aaaaaaaaaaa", watched: 0.2)])
        clock.set(local(3)); try load([video("aaaaaaaaaaa", watched: 0.2), video("bbbbbbbbbbb", watched: 0.7)])
        clock.set(local(4)); try load([video("aaaaaaaaaaa", watched: 0.2), video("bbbbbbbbbbb", watched: 0.7),
                                       video("ccccccccccc"), video("ddddddddddd"), video("eeeeeeeeeee"), video("fffffffffff")])
        clock.set(local(5)); try clew.checkIn(itemId: try id("ccccccccccc"))
        clock.set(local(9)); try clew.checkIn(itemId: try id("ddddddddddd"))
        clock.set(local(9, 12))
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.inProgress.map(\.item.externalRef) == ["bbbbbbbbbbb", "aaaaaaaaaaa"])   // most watched first
        #expect(Set(page.notStarted.map(\.item.externalRef)) == ["eeeeeeeeeee", "fffffffffff"])
        #expect(page.done.map(\.item.externalRef) == ["ddddddddddd", "ccccccccccc"])        // latest tick first
        #expect(page.done.map(\.doneToday) == [true, false])
        #expect(page.total == 6)
    }

    @Test func notStartedIsNewestFirst() throws {
        try load([video("aaaaaaaaaaa")])
        clock.set(local(3)); try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.notStarted.map(\.item.externalRef) == ["bbbbbbbbbbb", "aaaaaaaaaaa"])
    }

    @Test func theHeatmapKeepsTicksOfVideosThatLeftTheList() throws {
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        clock.set(local(3)); try clew.checkIn(itemId: try id("aaaaaaaaaaa"))
        clock.set(local(9)); try clew.checkIn(itemId: try id("bbbbbbbbbbb"))
        try load([video("ccccccccccc")])                            // a and b removed on YouTube
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.done.isEmpty && page.total == 1)
        let tue = LocalDay(string: "2026-11-03")!, mon = LocalDay(string: "2026-11-09")!
        #expect(page.finishedByDay == [tue: 1, mon: 1])
        #expect(page.finishedThisWeek == 1 && page.finishedLast30 == 2 && page.finishedAllTime == 2)
    }

    @Test func theLast30DaysLeaveOutOlderTicks() throws {
        clock.set(local(2).addingTimeInterval(-40 * 86_400))          // late September
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        try clew.checkIn(itemId: try id("aaaaaaaaaaa"))
        clock.set(local(9)); try clew.checkIn(itemId: try id("bbbbbbbbbbb"))
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.finishedLast30 == 1 && page.finishedAllTime == 2)
    }

    @Test func theRowAndThePageAgreeWhenTheClockMovesBack() throws {
        try load([video("aaaaaaaaaaa")])
        clock.set(local(9)); try clew.checkIn(itemId: try id("aaaaaaaaaaa"))
        clock.set(local(8))                                             // e.g. time zone moved back
        #expect(try clew.collections().first?.done == 1)
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.done.count == 1 && page.notStarted.isEmpty)
        #expect(page.finishedAllTime == 0)                              // the heatmap shows up to today only
    }

    @Test func anEmptiedListKeepsItsRowWhileItHasHistory() throws {
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        try clew.checkIn(itemId: try id("aaaaaaaaaaa"))
        try clew.deleteItem(itemId: try id("bbbbbbbbbbb"))
        try clew.deleteItem(itemId: try id("aaaaaaaaaaa"))
        let row = try #require(try clew.collections().first)
        #expect(row.total == 0 && row.done == 0)
        #expect(try clew.collection(.extensionYouTube)?.finishedAllTime == 1)
    }

    @Test func aTickCanBeUndoneTheSameDay() throws {
        try load([video("aaaaaaaaaaa")])
        let a = try id("aaaaaaaaaaa")
        try clew.checkIn(itemId: a)
        #expect(try clew.collection(.extensionYouTube)?.done.first?.doneToday == true)
        try clew.undoToday(itemId: a)
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.done.isEmpty && page.notStarted.count == 1 && page.finishedAllTime == 0)
    }
}
