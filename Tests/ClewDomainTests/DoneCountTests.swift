import ClewDomain
import Foundation
import Testing

/// SPEC 2026-11-18: each item once on each day it was done.
@Suite struct DoneCountTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func item(_ kind: ItemKind, source: Source = .user, deleted: Bool = false) -> Item {
        Item(id: UUID(), kind: kind, title: "i", schedule: .daily, progress: kind == .goal ? .counter(target: 300) : .none,
             state: .active, sortKey: 1, source: source, createdAt: t0, updatedAt: t0, deletedAt: deleted ? t0 : nil)
    }
    func tick(_ i: Item, _ d: String, _ amount: Int = 1, voided: Bool = false) -> (checkIn: CheckIn, item: Item) {
        (CheckIn(id: UUID(), itemId: i.id, localDay: day(d), at: t0, timeZoneId: "UTC", amount: amount,
                 source: .user, voidedAt: voided ? t0 : nil), i)
    }

    @Test func eachItemOnceADay() {
        let book = item(.goal), habit = item(.habit), task = item(.once)
        let counts = DoneCount.byDay([
            tick(book, "2026-11-10"), tick(book, "2026-11-10", 39),         // 40 pages: 1
            tick(habit, "2026-11-10"), tick(task, "2026-11-10"),
            tick(book, "2026-11-11"),
        ])
        #expect(counts == [day("2026-11-10"): 3, day("2026-11-11"): 1])
    }

    @Test func undoneAndCollectionsLeftOutDeletedKept() {
        let video = item(.link, source: .extensionYouTube), post = item(.link, source: .extensionX)
        let gone = item(.habit, deleted: true), undone = item(.once)
        let counts = DoneCount.byDay([
            tick(video, "2026-11-10"), tick(post, "2026-11-10"),
            tick(gone, "2026-11-10"), tick(undone, "2026-11-10", voided: true),
        ])
        #expect(counts == [day("2026-11-10"): 1])
    }

    @Test func aVoidedTickDoesNotHideALiveOneThatDay() {
        let book = item(.goal)
        #expect(DoneCount.byDay([tick(book, "2026-11-10", voided: true), tick(book, "2026-11-10")])
                == [day("2026-11-10"): 1])
    }
}
