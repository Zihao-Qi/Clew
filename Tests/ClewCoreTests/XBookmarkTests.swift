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
    private func scan(_ refs: [String], run: Int? = nil, found: Int? = nil) throws -> ImportResult {
        try clew.importExternal(ImportBatch(source: .extensionX, entries: refs.map { post($0) }, listTotal: nil,
            scan: ScanReport(found: found ?? refs.count, parsed: refs.count, selectorVersion: "t"),
            fromTop: run ?? refs.count))
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
        // What the user deleted in Clew stays gone.
        try clew.deleteItem(itemId: try #require(item(b)).id)
        #expect(try clew.bookmarkChanged(source: .extensionX, entry: post(b), bookmarked: true).restored == 0)
        #expect(item(b)?.deletedAt != nil && store.state.items.count == 2)
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
        // Gemini review: E then C bookmarked again on the phone, so the list is C E A B D.
        // Once the run reaches the posts that never moved, D is safe and real gaps count.
        #expect(rule("ABCDE", "CEAB").removed.isEmpty)
        #expect(rule("ABCDE", "CEABD").removed.isEmpty)
        #expect(rule("ABCDE", "CEAD").removed == ["B"])
        #expect(rule("AXB", "ABAB").removed == ["X"])               // never twice
    }
}
