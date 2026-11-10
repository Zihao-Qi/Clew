import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ m: Int, _ d: Int, _ h: Int = 10) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
}

private func video(_ ref: String, _ title: String = "A video", watched: Double? = nil) -> ExternalEntry {
    ExternalEntry(externalRef: ref, title: title, progress: watched)
}

private let a = "aaaaaaaaaaa", b = "bbbbbbbbbbb", c = "ccccccccccc", d = "ddddddddddd"

@Suite struct ImportTests {
    let store = FakeStore()
    let clock = TestClock(local(11, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    private func batch(_ entries: [ExternalEntry], total: Int?) -> ImportBatch {
        ImportBatch(source: .extensionYouTube, entries: entries, listTotal: total,
                    scan: ScanReport(found: entries.count, parsed: entries.count, selectorVersion: "t"))
    }
    /// Items on the YouTube collection now.
    private func listed() throws -> Int { try clew.collections().first { $0.source == .extensionYouTube }?.total ?? 0 }
    private func imported(_ ref: String) -> Item? {
        store.state.items.values.first { $0.externalRef == ref }
    }

    @Test func newVideosBecomeLinksInLaterWithTheirOwnURL() throws {
        let r = try clew.importExternal(batch([video(a, "  First\n video "), video(b)], total: 2))
        #expect(r.added == 2 && r.complete)
        let item = try #require(imported(a))
        #expect(item.kind == .link && item.state == .later && item.source == .extensionYouTube)
        #expect(item.title == "First video")
        #expect(item.titleOrigin == .fetched)                    // stranger-written (AGENT §4)
        #expect(item.url == URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa"))
        #expect(try listed() == 2)
        #expect(try clew.today().rows.isEmpty)
    }

    @Test func rescanningNeverDuplicates() throws {
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        let again = try clew.importExternal(batch([video(a), video(b), video(a)], total: 2))
        #expect(again == ImportResult(complete: true))
        #expect(store.state.items.count == 2)
    }

    @Test func malformedEntriesAreSkippedAndBlockRemovals() throws {
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        // A bad id or an empty title means the scraper misread the page.
        let r = try clew.importExternal(batch([video(a), video("short"), video(c, " \n ")], total: 1))
        #expect(r.skipped == 2 && !r.complete && r.letGo == 0)
        #expect(imported(b)?.deletedAt == nil)
        #expect(imported("short") == nil && imported(c) == nil)
    }

    @Test func idsWithOtherCharactersAreRejected() throws {
        let r = try clew.importExternal(batch([video("aaaaaaaaaa/"), video("aaaaaaaaaa?"), video("aaaaaaaaaaaa")], total: 3))
        #expect(r.skipped == 3 && r.added == 0)
    }

    @Test func aRenamedVideoUpdatesOnlyTitlesTheUserNeverEdited() throws {
        try clew.importExternal(batch([video(a, "old"), video(b, "old")], total: 2))
        let edited = try #require(imported(b))
        try clew.editItem(id: edited.id, ItemEdit(title: "mine", url: edited.url))
        let r = try clew.importExternal(batch([video(a, "new"), video(b, "new")], total: 2))
        #expect(r.renamed == 1)
        #expect(imported(a)?.title == "new" && imported(b)?.title == "mine")
    }

    @Test func aWholeListScanLetsGoUntouchedLaterItemsThatLeftIt() throws {
        try clew.importExternal(batch([video(a), video(b), video(c)], total: 3))
        let r = try clew.importExternal(batch([video(a)], total: 1))
        #expect(r.letGo == 2 && r.complete)
        #expect(imported(b)?.deletedAt != nil && imported(c)?.deletedAt != nil)
        #expect(try listed() == 1)
        // Recorded as the import's decision, not counted as the user's win.
        #expect(store.state.laterReviews.values.allSatisfy { $0.decision == .letGo && $0.source == .extensionYouTube })
        #expect(try clew.lettingGoCount() == 0)
    }

    @Test func aLetGoItemTakesItsReminderWithIt() throws {
        try clew.importExternal(batch([video(a)], total: 1))
        let item = try #require(imported(a))
        try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 18, minute: 0))
        try clew.importExternal(batch([video(d)], total: 1))
        #expect(try clew.reminder(forItem: item.id) == nil)
        #expect(store.state.reminders.values.allSatisfy { $0.deletedAt != nil })
    }

    @Test func aPartialScanNeverLetsGo() throws {
        try clew.importExternal(batch([video(a), video(b), video(c)], total: 3))
        // The page has loaded 1 of its 3 rows, or its count could not be read.
        #expect(try clew.importExternal(batch([video(a)], total: 3)).letGo == 0)
        #expect(try clew.importExternal(batch([video(a)], total: nil)).letGo == 0)
        #expect(try clew.importExternal(batch([], total: nil)).letGo == 0)
        #expect(try listed() == 3)
    }

    @Test func anEmptyListNeverLetsGo() throws {
        // "No videos" also shows on a signed-out or broken page; an empty read is never
        // trusted as the whole list (review of v1.1 step 1).
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        let r = try clew.importExternal(batch([], total: 0))
        #expect(!r.complete && r.letGo == 0)
        #expect(try listed() == 2)
    }

    @Test func rowsTheScraperCouldNotReadMeanNotTheWholeList() throws {
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        // 2 rows on the page, 1 read, and a stray count that happens to say 1.
        let scan = ScanReport(found: 2, parsed: 1, selectorVersion: "t")
        let r = try clew.importExternal(ImportBatch(source: .extensionYouTube, entries: [video(a)], listTotal: 1, scan: scan))
        #expect(!r.complete && r.letGo == 0)
        // No scan report at all: not trusted either.
        #expect(try !clew.importExternal(ImportBatch(source: .extensionYouTube, entries: [video(a)], listTotal: 1)).complete)
        #expect(try listed() == 2)
    }

    @Test func whatLeftTheListLeavesTheCollectionTickedOrNot() throws {
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        let done = try #require(imported(b))
        try clew.checkIn(itemId: done.id)                       // ticked on the collection's page
        let own = try clew.addItem(NewItem(title: "mine", url: URL(string: "https://www.youtube.com/watch?v=ccccccccccc"),
                                           shape: .later))
        let r = try clew.importExternal(batch([video(d)], total: 1))
        #expect(r.letGo == 2)                                   // SPEC 2026-11-09: ticked ones leave too
        #expect(imported(a)?.deletedAt != nil && imported(b)?.deletedAt != nil)
        #expect(store.state.checkIns.values.allSatisfy { $0.voidedAt == nil })   // the tick stays
        #expect(try clew.collection(.extensionYouTube)?.finishedAllTime == 1)
        #expect(store.state.items[own.id]?.deletedAt == nil)    // the user's own item
    }

    @Test func collectionItemsStayInTheirCollection() throws {
        try clew.importExternal(batch([video(a)], total: 1))
        let item = try #require(imported(a))
        #expect(throws: ClewError.notAllowed) { try clew.planForToday(itemIds: [item.id]) }
        #expect(try clew.laterCount() == 0 && clew.laterPile().isEmpty && clew.laterItems().isEmpty)
        #expect(try clew.today().rows.isEmpty)
        // Picked before collections existed: still not on Today.
        try store.write { w in
            var i = try #require(try w.item(id: item.id))
            i.state = .active; i.plannedDay = clew.currentDay(); i.sortKey = 0.5   // off the 1, 2, 3… grid
            try w.update(i)
        }
        #expect(try clew.today().rows.isEmpty)
        // ...is left out when Today's order is renumbered (80 moves into one gap force it)...
        let sortKey = try #require(imported(a)).sortKey
        let first = try clew.addItem(NewItem(title: "first", shape: .habit(.daily)))
        var below = try clew.addItem(NewItem(title: "last", shape: .habit(.daily))).id
        for i in 0..<80 {
            let x = try clew.addItem(NewItem(title: "x\(i)", shape: .habit(.daily)))
            try clew.moveItem(id: x.id, after: first.id, before: below)
            below = x.id
        }
        #expect(imported(a)?.sortKey == sortKey)
        // ...and never reminds about it.
        try clew.setReminder(itemId: item.id, time: TimeOfDay(hour: 23, minute: 0))
        #expect(try clew.plannedNotifications().isEmpty)
    }

    @Test func aVideoBackOnTheListIsRestored() throws {
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        clock.set(local(11, 10))
        try clew.importExternal(batch([video(a)], total: 1))
        clock.set(local(11, 11))
        let r = try clew.importExternal(batch([video(a), video(b)], total: 2))
        #expect(r.restored == 1 && r.added == 0)
        let item = try #require(imported(b))
        #expect(item.deletedAt == nil && item.state == .later)
        #expect(store.state.laterReviews.values.allSatisfy { $0.voidedAt != nil })
        #expect(store.state.items.count == 2)
    }

    @Test func whatTheUserDeletedOrLetGoStaysGone() throws {
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        try clew.deleteItem(itemId: try #require(imported(a)).id)
        try clew.letGo(itemId: try #require(imported(b)).id)
        let r = try clew.importExternal(batch([video(a), video(b)], total: 2))
        #expect(r.restored == 0 && r.added == 0)
        #expect(imported(a)?.deletedAt != nil && imported(b)?.deletedAt != nil)
        #expect(try listed() == 0)
    }

    @Test func aLetGoAfterTheImportsOwnIsTheUsers() throws {
        // Imported, let go by the import, restored, then let go by the user: stays gone.
        try clew.importExternal(batch([video(a)], total: 1))
        try clew.importExternal(batch([video(d)], total: 1))
        try clew.importExternal(batch([video(a)], total: 1))
        try clew.letGo(itemId: try #require(imported(a)).id)
        #expect(try clew.importExternal(batch([video(a)], total: 1)).restored == 0)
        #expect(imported(a)?.deletedAt != nil)
    }

    // MARK: Watch progress (read from the Watch Later page)

    @Test func watchProgressIsKeptAndRewrittenOnlyWhenItChanges() throws {
        let first = try clew.importExternal(batch([video(a, watched: 0.4), video(b)], total: 2))
        #expect(first.progressed == 1)
        let ida = try #require(imported(a)).id, idb = try #require(imported(b)).id
        #expect(try clew.watchProgress(itemIds: [ida, idb]) == [ida: 0.4])
        clock.set(local(11, 10))
        #expect(try clew.importExternal(batch([video(a, watched: 0.4), video(b)], total: 2)).progressed == 0)
        #expect(store.state.watchProgress[ida]?.observedAt == local(11, 9))   // re-scans write nothing
        let moved = try clew.importExternal(batch([video(a, watched: 0.86), video(b)], total: 2))
        #expect(moved.progressed == 1)
        #expect(store.state.watchProgress[ida]?.fraction == 0.86)
        #expect(store.state.watchProgress[ida]?.observedAt == local(11, 10))
        #expect(store.state.watchProgress[ida]?.source == .extensionYouTube)
    }

    @Test func progressNeverTicksAndDoesNotRestartTheLaterClock() throws {
        try clew.importExternal(batch([video(a), video(b)], total: 2))
        let before = try #require(imported(a))
        clock.set(local(11, 12))
        try clew.importExternal(batch([video(a, watched: 1), video(b, watched: 1)], total: 2))
        let after = try #require(imported(a))
        #expect(after.state == .later && after.updatedAt == before.updatedAt)
        #expect(store.state.checkIns.isEmpty)                  // SPEC 2026-11-09: never ticks
        let page = try #require(try clew.collection(.extensionYouTube))
        #expect(page.inProgress.map(\.watched) == [1, 1] && page.done.isEmpty)
    }

    @Test func unreadableProgressIsIgnoredButTheVideoIsImported() throws {
        let r = try clew.importExternal(batch(
            [video(a, watched: 1.5), video(b, watched: -0.1), video(c, watched: .nan), video(d, watched: 0.333)], total: 4))
        #expect(r.added == 4 && r.skipped == 0 && r.progressed == 1)
        #expect(store.state.watchProgress.values.map(\.fraction) == [0.33])
    }

    @Test func aVideoTheUserDeletedGetsNoProgress() throws {
        try clew.importExternal(batch([video(a)], total: 1))
        try clew.deleteItem(itemId: try #require(imported(a)).id)
        #expect(try clew.importExternal(batch([video(a, watched: 0.5)], total: 1)).progressed == 0)
        #expect(store.state.watchProgress.isEmpty)
    }

    @Test func onlyImportSourcesAndBoundedBatches() throws {
        #expect(throws: ClewError.notAllowed) {
            try clew.importExternal(ImportBatch(source: .user, entries: [video(a)], listTotal: 1))
        }
        let many = (0...Clew.maxImportEntries).map { video(String(format: "v%010d", $0)) }
        #expect(throws: ClewError.tooManyEntries(max: Clew.maxImportEntries)) {
            try clew.importExternal(batch(many, total: nil))
        }
    }

    @Test func longTitlesAreCut() throws {
        try clew.importExternal(batch([video(a, String(repeating: "x", count: 500))], total: 1))
        let title = try #require(imported(a)).title
        #expect(title.count == Clew.maxTitleLength && title.hasSuffix("…"))
    }
}

@Suite struct ScanHealthTests {
    @Test func aPageThatShouldHaveItemsButParsedNoneNeedsAnUpdate() {
        let ok = ImportResult(complete: true)
        #expect(!ScanReport(found: 3, parsed: 3, selectorVersion: "1").needsUpdate(listTotal: 3, result: ok))
        #expect(!ScanReport(found: 0, parsed: 0, selectorVersion: "1").needsUpdate(listTotal: 0, result: ok))
        #expect(!ScanReport(found: 0, parsed: 0, selectorVersion: "1").needsUpdate(listTotal: nil, result: ok))
        // Rows found but unreadable, a count with no rows read, or entries Clew rejected.
        #expect(ScanReport(found: 3, parsed: 2, selectorVersion: "1").needsUpdate(listTotal: 3, result: ok))
        #expect(ScanReport(found: 0, parsed: 0, selectorVersion: "1").needsUpdate(listTotal: 12, result: ok))
        #expect(ScanReport(found: 2, parsed: 2, selectorVersion: "1").needsUpdate(listTotal: 2, result: ImportResult(skipped: 1)))
    }
}
