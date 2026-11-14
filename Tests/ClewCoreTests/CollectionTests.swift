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
        #expect(row.source == .extensionYouTube && row.toWatch == 3 && row.done == 1 && row.onList == 4)
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

    @Test func notStartedFollowsWatchLatersOwnOrder() throws {
        // All videos of one scan arrive at the same moment, so "newest first" was no order
        // at all; the page follows Watch Later instead (2026-11-10).
        try load([video("ccccccccccc"), video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        #expect(try clew.collection(.extensionYouTube)?.notStarted.map(\.item.externalRef)
                == ["ccccccccccc", "aaaaaaaaaaa", "bbbbbbbbbbb"])
        clock.set(local(3)); try load([video("bbbbbbbbbbb"), video("ccccccccccc"), video("aaaaaaaaaaa")])   // reordered
        #expect(try clew.collection(.extensionYouTube)?.notStarted.map(\.item.externalRef)
                == ["bbbbbbbbbbb", "ccccccccccc", "aaaaaaaaaaa"])
        // A partial scan keeps the rest where it was.
        try clew.importExternal(ImportBatch(source: .extensionYouTube, entries: [video("aaaaaaaaaaa")], listTotal: 3))
        #expect(try clew.collection(.extensionYouTube)?.notStarted.map(\.item.externalRef)
                == ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
    }

    @Test func ticksOfVideosThatLeftTheListStayInDoneAndTheHeatmap() throws {
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        clock.set(local(3)); try clew.checkIn(itemId: try id("aaaaaaaaaaa"))
        clock.set(local(9)); try clew.checkIn(itemId: try id("bbbbbbbbbbb"))
        try load([video("ccccccccccc")])                            // a and b removed on YouTube
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.done.map(\.item.externalRef) == ["bbbbbbbbbbb", "aaaaaaaaaaa"] && page.toWatch == 1)
        #expect(page.done.allSatisfy { !$0.onList })
        #expect(store.state.checkIns.count == 2)                    // already ticked: not ticked again
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

    @Test func anEmptiedListKeepsItsRowWhileItHasSomethingDone() throws {
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb"), video("ccccccccccc")])
        clock.set(local(3)); try load([video("bbbbbbbbbbb"), video("ccccccccccc")])   // a left: finished
        try clew.deleteItem(itemId: try id("bbbbbbbbbbb"))
        try clew.deleteItem(itemId: try id("ccccccccccc"))
        let row = try #require(try clew.collections().first)
        #expect(row.toWatch == 0 && row.done == 1 && row.onList == 0)
        #expect(try clew.collection(.extensionYouTube)?.finishedAllTime == 1)
    }

    @Test func whatTheUserDeletedLeavesTheHeatmapToo() throws {
        // User, 2026-11-10: a deleted article still coloured the heatmap while Done said 0.
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        try clew.checkIn(itemId: try id("aaaaaaaaaaa"))
        try clew.deleteItem(itemId: try id("aaaaaaaaaaa"))
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.done.isEmpty && page.finishedByDay.isEmpty)
        #expect(page.finishedThisWeek == 0 && page.finishedLast30 == 0 && page.finishedAllTime == 0)
        #expect(try clew.collections().first?.done == 0)
        // With nothing left and nothing done, the row goes.
        try clew.deleteItem(itemId: try id("bbbbbbbbbbb"))
        #expect(try clew.collections().isEmpty)
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

    // MARK: Removed means finished (SPEC decision 2026-11-10)

    @Test func aVideoThatLeftTheListCountsAsFinishedTheDayItWasSeenGone() throws {
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb"), video("ccccccccccc", watched: 0.1)])
        clock.set(local(9)); try load([video("aaaaaaaaaaa")])       // b never started, c barely
        let ticks = store.state.checkIns.values.filter { $0.voidedAt == nil }
        #expect(ticks.count == 2 && ticks.allSatisfy { $0.localDay == LocalDay(string: "2026-11-09")! })
        #expect(ticks.allSatisfy { $0.source == .extensionYouTube && $0.amount == 1 })
        let row = try #require(try clew.collections().first)
        #expect(row.toWatch == 1 && row.done == 2 && row.onList == 1)
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(Set(page.done.map(\.item.externalRef)) == ["bbbbbbbbbbb", "ccccccccccc"])
        #expect(page.finishedByDay == [LocalDay(string: "2026-11-09")!: 2])
        // Scanning the same list again finishes nothing more.
        clock.set(local(10)); try load([video("aaaaaaaaaaa")])
        #expect(store.state.checkIns.count == 2)
    }

    @Test func notFinishedTakesItOutOfDoneAndTheHeatmap() throws {
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb"), video("ccccccccccc")])
        try clew.deleteItem(itemId: try id("ccccccccccc"))
        try load([video("aaaaaaaaaaa")])
        let b = try id("bbbbbbbbbbb")
        try clew.markNotFinished(itemId: b)
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.done.isEmpty && page.total == 1 && page.finishedAllTime == 0)
        #expect(try clew.collections().first?.done == 0)
        // Only for what left the list: not one still on it, one the user deleted, or a task.
        #expect(throws: ClewError.notAllowed) { try clew.markNotFinished(itemId: try id("aaaaaaaaaaa")) }
        #expect(throws: ClewError.notAllowed) { try clew.markNotFinished(itemId: try id("ccccccccccc")) }
        let task = try clew.addItem(NewItem(title: "t", shape: .later))
        try clew.letGo(itemId: task.id)                              // removed by a let-go, but the user's
        #expect(throws: ClewError.notAllowed) { try clew.markNotFinished(itemId: task.id) }
        // Back on Watch Later, it is to watch again.
        clock.set(local(3)); try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        #expect(try clew.collection(.extensionYouTube)?.notStarted.map(\.item.externalRef).contains("bbbbbbbbbbb") == true)
    }

    @Test func aVideoBackOnWatchLaterIsToWatchAgainButKeepsTheUsersTick() throws {
        // Review of 2026-11-10 (Gemini): a restored video kept the import's tick and was
        // stuck in Done.
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb"), video("ccccccccccc")])
        try clew.checkIn(itemId: try id("ccccccccccc"))             // the user finished c
        clock.set(local(3)); try load([video("aaaaaaaaaaa")])        // b and c leave
        clock.set(local(4)); try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb"), video("ccccccccccc")])
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(Set(page.notStarted.map(\.item.externalRef)) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(page.done.map(\.item.externalRef) == ["ccccccccccc"] && page.done.allSatisfy(\.onList))
        #expect(page.finishedAllTime == 1)
        let voided = store.state.checkIns.values.filter { $0.voidedAt != nil }
        #expect(voided.count == 1 && voided.allSatisfy { $0.source == .extensionYouTube })
    }

    @Test func aVideoRemovedAMomentAgoIsNotBroughtBackByAStaleScan() throws {
        // Gemini review: the 10-minute wait was only tested for X.
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])
        try load([video("aaaaaaaaaaa")])                            // b removed: finished
        clock.set(local(2).addingTimeInterval(Clew.restoreAfter - 1))
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])      // another tab, still showing b
        #expect(try clew.collection(.extensionYouTube)?.done.map(\.item.externalRef) == ["bbbbbbbbbbb"])
        clock.set(local(2).addingTimeInterval(Clew.restoreAfter + 1))
        try load([video("aaaaaaaaaaa"), video("bbbbbbbbbbb")])      // really back on Watch Later
        #expect(try clew.collection(.extensionYouTube)?.notStarted.contains { $0.item.externalRef == "bbbbbbbbbbb" } == true)
    }

    // MARK: On and off

    @Test func aListTurnedOffIsHiddenAndImportsNothing() throws {
        try load([video("aaaaaaaaaaa")])
        try clew.setCollection(.extensionYouTube, on: false)
        #expect(try clew.collectionsOff() == [.extensionYouTube])
        #expect(try clew.collections().isEmpty)
        #expect(throws: ClewError.listTurnedOff) { try load([video("bbbbbbbbbbb")]) }
        #expect(store.state.items.count == 1 && store.state.checkIns.isEmpty)   // nothing added or finished
        try clew.setCollection(.extensionYouTube, on: true)
        #expect(try clew.collections().first?.toWatch == 1)
        try load([video("bbbbbbbbbbb")])
        #expect(store.state.items.count == 2)
        #expect(throws: ClewError.notAllowed) { try clew.setCollection(.user, on: false) }
    }

    @Test func anUnknownListInTheSettingIsIgnored() throws {
        try store.write { try $0.saveSetting("collectionsOff", json: #"["extension.youtube","newer.site"]"#, updatedAt: local(2)) }
        #expect(try clew.collectionsOff() == [.extensionYouTube])
        try store.write { try $0.saveSetting("collectionsOff", json: #"{"bad":1}"#, updatedAt: local(2)) }
        #expect(try clew.collectionsOff().isEmpty)
    }
}
