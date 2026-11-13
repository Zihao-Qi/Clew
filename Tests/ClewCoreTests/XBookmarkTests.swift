import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ d: Int, _ h: Int = 10) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
}

private func post(_ ref: String, _ title: String = "a post") -> ExternalEntry {
    ExternalEntry(externalRef: ref, title: title)
}

private let a = "1850000000000000001", b = "1850000000000000002", c = "1850000000000000003",
            d = "1850000000000000004", e = "1850000000000000005", n = "1850000000000000009"

/// SPEC decision 2026-11-10: X bookmarks are a collection read as you scroll. With no
/// count on the page, removals come from the gap rule and the bookmark button.
@Suite struct XBookmarkTests {
    let store = FakeStore()
    let clock = TestClock(local(9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    /// A scan of `refs`, top first, the first `run` of them unbroken from the top.
    @discardableResult
    private func scan(_ refs: [String], run: Int? = nil, found: Int? = nil, end: Bool? = nil) throws -> ImportResult {
        try clew.importExternal(ImportBatch(source: .extensionX, entries: refs.map { post($0) }, listTotal: nil,
            scan: ScanReport(found: found ?? refs.count, parsed: refs.count, selectorVersion: "t"),
            fromTop: run ?? refs.count, reachedEnd: end))
    }
    /// `count` post ids, distinct from a…n.
    private func many(_ count: Int, from start: Int = 100) -> [String] {
        (start..<(start + count)).map { "18600000000000\(String(format: "%05d", $0))" }
    }
    private func item(_ ref: String) -> Item? { store.state.items.values.first { $0.externalRef == ref } }
    private func page() throws -> CollectionDetails { try #require(try clew.collection(.extensionX)) }
    private func toRead() throws -> Set<String> { Set(try page().notStarted.compactMap(\.item.externalRef)) }
    private func read() throws -> Set<String> { Set(try page().done.compactMap(\.item.externalRef)) }

    @Test func postsBecomeACollectionWithTheirOwnLinks() throws {
        let r = try clew.importExternal(ImportBatch(source: .extensionX, entries: [
            post(a, "  Hello\nworld "), post("0123"), post("12x"), post("12345678901234567890"), post("9999999999999999999"),
        ], listTotal: nil, scan: ScanReport(found: 5, parsed: 5, selectorVersion: "t"), fromTop: 5))
        #expect(r.added == 1 && r.skipped == 4 && !r.complete)
        let i = try #require(item(a))
        #expect(i.url == URL(string: "https://x.com/i/status/1850000000000000001") && i.title == "Hello world")
        #expect(i.titleOrigin == .fetched && i.source == .extensionX)
        let row = try #require(try clew.collections().first { $0.source == .extensionX })
        #expect(row.toWatch == 1 && row.onList == 1)
        #expect(try clew.today().total == 0 && clew.laterPile().isEmpty)
    }

    @Test func toReadFollowsXsOrderNewestBookmarkFirst() throws {
        try scan([c, a, b])
        #expect(try page().notStarted.compactMap(\.item.externalRef) == [c, a, b])
        try clew.bookmarkChanged(source: .extensionX, entry: post(n), bookmarked: true)
        #expect(try page().notStarted.compactMap(\.item.externalRef) == [n, c, a, b])
    }

    @Test func aPostMissingBetweenTwoStillThereWasRead() throws {
        try scan([a, b, c, d, e])
        clock.set(local(10))
        let r = try scan([a, c, d])                                 // b unbookmarked on the phone
        #expect(r.letGo == 1)
        #expect(try read() == [b] && toRead() == [a, c, d, e])      // e is below what was seen: kept
        let tick = try #require(store.state.checkIns.values.first)
        #expect(tick.localDay == LocalDay(string: "2026-11-10")! && tick.source == .extensionX)
    }

    @Test func theNewestBookmarkRemovedOnThePhoneIsCaught() throws {
        try scan([a, b, c])
        clock.set(local(10))
        #expect(try scan([b, c]).letGo == 1)
        #expect(try read() == [a])
    }

    @Test func newPostsOnTopDoNotHideAGap() throws {
        try scan([a, b, c])
        try scan([n, a, c])
        #expect(try read() == [b])
        try scan([a, n, c])                                         // unknown posts between are skipped over
        #expect(try read() == [b] && toRead() == [n, a, c])
    }

    @Test func aPostBookmarkedAgainMovesToTheTopWithoutMakingGaps() throws {
        try scan([a, b, c, d, e])
        try scan([e, a, b])                                         // e bookmarked again; c and d not loaded
        #expect(try read().isEmpty && toRead() == [a, b, c, d, e])
        try scan([e, a, c])                                         // now b is really gone
        #expect(try read() == [b])
    }

    @Test func onlyTheUnbrokenRunFromTheTopIsCompared() throws {
        try scan([a, b, c, d])
        // The scraper saw a, then lost the thread; c and d were seen after a break.
        let r = try scan([a, c, d], run: 1)
        #expect(try r.letGo == 0 && read().isEmpty)
        #expect(try scan([a, c, d], run: 0).letGo == 0)
        #expect(try scan([a, c, d], run: -1).letGo == 0)           // a nonsense run is no run
        #expect(try scan([a, c, d], run: 99).letGo == 1)           // clamped to the entries
    }

    @Test func aScanThatMissedRowsComparesNothing() throws {
        try scan([a, b, c])
        #expect(try scan([a, c], found: 3).letGo == 0)              // a row it could not read
        let bad = try clew.importExternal(ImportBatch(source: .extensionX, entries: [post(a), post("x"), post(c)],
            listTotal: nil, scan: ScanReport(found: 3, parsed: 3, selectorVersion: "t"), fromTop: 3))
        #expect(bad.skipped == 1 && bad.letGo == 0)                 // a malformed entry
        let noReport = try clew.importExternal(ImportBatch(source: .extensionX, entries: [post(a), post(c)],
            listTotal: nil, fromTop: 2))
        #expect(try noReport.letGo == 0 && read().isEmpty)
    }

    @Test func aListCountIsNeverTrustedForX() throws {
        try scan([a, b])
        let r = try clew.importExternal(ImportBatch(source: .extensionX, entries: [post(a)], listTotal: 1,
            scan: ScanReport(found: 1, parsed: 1, selectorVersion: "t"), fromTop: 0))
        #expect(!r.complete && r.letGo == 0)
    }

    @Test func whatTheUserDeletedNeverAnchorsOrLeavesAgain() throws {
        try scan([a, b, c])
        try clew.deleteItem(itemId: try #require(item(b)).id)
        try scan([a], run: 1)
        // The order Clew keeps holds only what is still in the collection.
        let order = try store.read { try $0.setting("listOrder.extension.x") }
        #expect(order == #"["\#(a)","\#(c)"]"#)
        let r = try scan([a, c])
        #expect(r.letGo == 0 && store.state.laterReviews.isEmpty && store.state.checkIns.isEmpty)
    }

    // MARK: The bookmark button

    @Test func bookmarkingAPostAlreadyThereMovesItToTheTop() throws {
        try scan([a, b, c])
        try clew.bookmarkChanged(source: .extensionX, entry: post(c), bookmarked: true)
        #expect(store.state.items.count == 3)
        // c is now on top: a run [c, b] says a was removed; with c still in its old
        // place, that run would have been a step back and proven nothing.
        try scan([c, b])
        #expect(try read() == [a])
    }

    @Test func aPostDeletedInClewLeavesTheOrderOnTheNextClick() throws {
        try scan([a, b, c])
        try clew.deleteItem(itemId: try #require(item(b)).id)
        try clew.bookmarkChanged(source: .extensionX, entry: post(n, "new"), bookmarked: true)
        let order = try store.read { try $0.setting("listOrder.extension.x") }
        #expect(order == #"["\#(n)","\#(a)","\#(c)"]"#)
    }

    @Test func bookmarkingAddsAtTheTopOfTheList() throws {
        try scan([a, b, c])
        let r = try clew.bookmarkChanged(source: .extensionX, entry: post(n, "just saved"), bookmarked: true)
        #expect(r.added == 1 && item(n)?.title == "just saved")
        // n is now the newest: a run [n, b] shows a was removed.
        try scan([n, b])
        #expect(try read() == [a])
    }

    @Test func unbookmarkingMarksItRead() throws {
        try scan([a, b])
        clock.set(local(11))
        let r = try clew.bookmarkChanged(source: .extensionX, entry: post(a, ""), bookmarked: false)
        #expect(try r.letGo == 1 && read() == [a])
        #expect(store.state.checkIns.values.map(\.localDay) == [LocalDay(string: "2026-11-11")!])
        // Again, or for a post Clew never saw: nothing more.
        #expect(try clew.bookmarkChanged(source: .extensionX, entry: post(a), bookmarked: false).letGo == 0)
        #expect(try clew.bookmarkChanged(source: .extensionX, entry: post(n), bookmarked: false).letGo == 0)
        #expect(store.state.checkIns.count == 1 && item(n) == nil)
        // Ticked by the user first: no second tick.
        try clew.checkIn(itemId: try #require(item(b)).id)
        try clew.bookmarkChanged(source: .extensionX, entry: post(b), bookmarked: false)
        #expect(store.state.checkIns.count == 2)
    }

    @Test func bookmarkingAgainBringsItBackToRead() throws {
        try scan([a, b])
        try clew.bookmarkChanged(source: .extensionX, entry: post(a), bookmarked: false)
        let r = try clew.bookmarkChanged(source: .extensionX, entry: post(a), bookmarked: true)
        #expect(try r.restored == 1 && toRead() == [a, b] && read().isEmpty)
        // Deleted in Clew, then bookmarked again: the click brings it back, to read
        // (user, 2026-11-10), even if it had been ticked before.
        try clew.checkIn(itemId: try #require(item(b)).id)
        try clew.deleteItem(itemId: try #require(item(b)).id)
        #expect(try clew.bookmarkChanged(source: .extensionX, entry: post(b), bookmarked: true).restored == 1)
        #expect(try toRead() == [a, b] && read().isEmpty && store.state.items.count == 2)
        #expect(store.state.checkIns.values.filter { $0.voidedAt == nil }.isEmpty)
    }

    @Test func aStaleScanCannotUndoAnUnbookmarkButAClickCan() throws {
        // Seen 19 → 18 → 19: a scan read before the click (or another tab) still lists it.
        try scan([a, b])
        clock.set(local(9, 12))
        try clew.bookmarkChanged(source: .extensionX, entry: post(a), bookmarked: false)
        clock.set(local(9, 12).addingTimeInterval(Clew.restoreAfter - 1))
        #expect(try scan([a, b]).restored == 0 && read() == [a])
        // Long enough after, it is really back on the list (bookmarked again on the phone).
        clock.set(local(9, 12).addingTimeInterval(Clew.restoreAfter + 1))
        #expect(try scan([a, b]).restored == 1 && toRead() == [a, b])
        // A click never waits, and it is a restore: a tick the user made stays.
        try clew.checkIn(itemId: try #require(item(b)).id)
        try clew.bookmarkChanged(source: .extensionX, entry: post(b), bookmarked: false)
        #expect(try clew.bookmarkChanged(source: .extensionX, entry: post(b), bookmarked: true).restored == 1)
        #expect(try read() == [b] && store.state.checkIns.values.contains { $0.itemId == item(b)?.id && $0.voidedAt == nil })
    }

    @Test func aScanNeverBringsBackWhatTheUserDeleted() throws {
        // A scan cannot tell "still bookmarked" from "bookmarked again": only a click can.
        try scan([a, b])
        try clew.deleteItem(itemId: try #require(item(b)).id)
        #expect(try scan([a, b]).restored == 0)
        #expect(item(b)?.deletedAt != nil)
        // ...and it keeps no place in the order even while still on the page (Gemini).
        let order = try store.read { try $0.setting("listOrder.extension.x") }
        #expect(order == #"["\#(a)"]"#)
    }

    @Test func aTickOfAPostThatLeftCannotBeUndoneHere() throws {
        // Gemini review: undoToday turned "left" into "not read" behind the table's back.
        try scan([a, b])
        try clew.bookmarkChanged(source: .extensionX, entry: post(a), bookmarked: false)
        #expect(try clew.undoToday(itemId: try #require(item(a)).id) == nil)
        #expect(try read() == [a])
        #expect(throws: ClewError.itemNotFound) { try clew.checkIn(itemId: try #require(item(a)).id) }
    }

    @Test func aBookmarkNeedsATitleAndAValidId() throws {
        #expect(try clew.bookmarkChanged(source: .extensionX, entry: post(a, "  "), bookmarked: true).skipped == 1)
        #expect(try clew.bookmarkChanged(source: .extensionX, entry: post("abc"), bookmarked: true).skipped == 1)
        #expect(store.state.items.isEmpty)
    }

    @Test func clicksAreOnlyForXAndNotWhileItIsOff() throws {
        #expect(throws: ClewError.notAllowed) {
            try clew.bookmarkChanged(source: .extensionYouTube, entry: post("aaaaaaaaaaa"), bookmarked: true)
        }
        try clew.setCollection(.extensionX, on: false)
        #expect(throws: ClewError.listTurnedOff) { try clew.bookmarkChanged(source: .extensionX, entry: post(a), bookmarked: true) }
        #expect(throws: ClewError.listTurnedOff) { try scan([a]) }
        #expect(store.state.items.isEmpty)
    }

    // MARK: The rule on its own

    // MARK: The end of the list (SPEC 2026-11-13)

    @Test func seeingTheEndClearsPostsRemovedBelowTheLastOne() throws {
        try scan([a, b, c, d, e])
        clock.set(local(10))
        // The user's case: removed on the phone, below and between what is left.
        let gap = try scan([a, c])
        #expect(try !gap.complete && toRead() == [a, c, d, e])     // the gap rule: b only
        let whole = try scan([a, c], end: true)
        #expect(whole.complete && whole.letGo == 2)
        #expect(try toRead() == [a, c] && read() == [b, d, e])
        #expect(try page().notStarted.compactMap(\.item.externalRef) == [a, c])
        // "Not read" undoes it, as any automatic read.
        let dItem = try #require(item(d))
        try clew.markNotFinished(itemId: dItem.id)
        #expect(try !read().contains(d))
    }

    @Test func theEndIsTrustedOnlyForAWholeUnbrokenReadablePage() throws {
        try scan([a, b, c, d])
        clock.set(local(10))
        try scan([a, b], run: 1, end: true)                            // a break after a
        try scan([a, b], found: 3, end: true)                          // a row it could not read
        try scan([], end: true)                                        // an empty page
        try scan([a, b], end: false)
        try scan([a, b])                                               // an older extension
        #expect(try toRead() == [a, b, c, d])
        // A malformed entry is skipped, so the page was not read whole either.
        try clew.importExternal(ImportBatch(source: .extensionX, entries: [post(a), post(b), post("0x")], listTotal: nil,
            scan: ScanReport(found: 3, parsed: 3, selectorVersion: "t"), fromTop: 3, reachedEnd: true))
        #expect(try toRead() == [a, b, c, d])
    }

    @Test func aPostClewChangedInTheLastTenMinutesStaysAndLeadsTheOrder() throws {
        try scan([a, b, c])
        clock.set(local(10))
        try clew.bookmarkChanged(source: .extensionX, entry: post(n), bookmarked: true)   // clicked in another tab
        clock.set(local(10).addingTimeInterval(9 * 60))
        let r = try scan([a, b], end: true)                           // this page loaded before the click
        #expect(try r.complete && r.letGo == 1 && read() == [c])
        #expect(try page().notStarted.compactMap(\.item.externalRef) == [n, a, b])
        // Once it is older than ten minutes, a page without it means it was removed.
        clock.set(local(10).addingTimeInterval(11 * 60))
        try scan([a, b], end: true)
        #expect(try read() == [c, n])
    }

    @Test func moreThanTwentyAndMoreThanHalfIsNotTrusted() throws {
        let old = many(30)
        try scan(old)
        clock.set(local(10))
        // 21 of 30 gone at once: a broken page, not a cleanup. The gap rule runs instead.
        let kept = Array(old.prefix(9))
        let r = try scan(kept, end: true)
        #expect(try !r.complete && r.letGo == 0 && toRead().count == 30)
        // 21 gone of 50 is less than half: trusted.
        let more = many(20, from: 200)
        try scan(more + old, run: 0)
        #expect(try toRead().count == 50)
        let r2 = try scan(more + kept, end: true)
        #expect(try r2.complete && r2.letGo == 21 && toRead().count == 29)
        // 20 gone, more than half but not more than 20, is within the cap (the newer
        // posts are past their ten minutes by then).
        clock.set(local(10).addingTimeInterval(11 * 60))
        let r3 = try scan(Array(more.prefix(9)), end: true)
        #expect(r3.complete && r3.letGo == 20)
    }

    @Test func gapRuleCases() {
        typealias G = (order: [String], removed: [String])
        func rule(_ p: String, _ t: String) -> G {
            Clew.gapRule(previous: p.map(String.init), top: t.map(String.init))
        }
        #expect(rule("ABCDE", "ACD") == (Array("ACDE").map(String.init), ["B"]))
        #expect(rule("ABCDE", "AE").removed == ["B", "C", "D"])
        #expect(rule("ABCDE", "EAB").removed.isEmpty)
        #expect(rule("ABCDE", "EAB").order == Array("EABCD").map(String.init))
        #expect(rule("ABC", "XYZ") == (Array("XYZABC").map(String.init), []))
        #expect(rule("", "AB").order == ["A", "B"])
        #expect(rule("ABC", "").order == ["A", "B", "C"])
        #expect(rule("ABC", "AAC") == (["A", "C"], ["B"]))         // a repeated row counts once
        #expect(rule("ABCD", "ACBD").removed.isEmpty)               // what is on the page is never removed
        #expect(rule("ABC", "BC").removed == ["A"])                 // the newest one, gone from the top
        #expect(rule("ABC", "XBC").removed == ["A"])                // ...with a new one above
        #expect(rule("ABC", "XY").removed.isEmpty)                  // nothing known: nothing decided
        #expect(rule("ABCDE", "EBC").removed.isEmpty)               // out of order: the top proves nothing
        // Gemini review: E then C bookmarked again on the phone, so the list is C E A B D.
        // Once the run reaches the posts that never moved, D is safe and real gaps count.
        #expect(rule("ABCDE", "CEAB").removed.isEmpty)
        #expect(rule("ABCDE", "CEABD").removed.isEmpty)
        #expect(rule("ABCDE", "CEAD").removed == ["B"])
        #expect(rule("AXB", "ABAB").removed == ["X"])               // never twice
    }
}
