import ClewDomain
import Foundation
import Testing

/// SPEC 2026-11-15, "Last week's card": what one Monday-to-Sunday week shows.
@Suite struct WeekRecapTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // Monday 2026-11-09 to Sunday 2026-11-15.
    let monday = day("2026-11-09")

    func item(_ kind: ItemKind, _ title: String = "i", sortKey: Double = 1, source: Source = .user,
              deleted: Bool = false) -> Item {
        Item(id: UUID(), kind: kind, title: title, schedule: .daily,
             progress: kind == .goal ? .counter(target: 20) : .none, state: .active, sortKey: sortKey,
             source: source, createdAt: t0, updatedAt: t0, deletedAt: deleted ? t0 : nil)
    }
    func tick(_ i: Item, _ d: String, _ amount: Int = 1, voided: Bool = false) -> (checkIn: CheckIn, item: Item) {
        (CheckIn(id: UUID(), itemId: i.id, localDay: day(d), at: t0, timeZoneId: "UTC", amount: amount,
                 source: .user, voidedAt: voided ? t0 : nil), i)
    }
    func focus(_ i: Item, _ d: String, _ minutes: Int, voided: Bool = false) -> FocusSession {
        FocusSession(id: UUID(), itemId: i.id, localDay: day(d), at: t0, minutes: minutes, kind: .timer,
                     voidedAt: voided ? t0 : nil)
    }
    func make(_ ticks: [(checkIn: CheckIn, item: Item)], focus: [FocusSession] = [], userDeleted: Set<UUID> = [],
              listsOff: Set<Source> = []) -> WeekRecap? {
        WeekRecap.make(weekStart: monday, ticks: ticks, focus: focus, userDeleted: userDeleted, listsOff: listsOff)
    }

    @Test func doneSumsTheWeeksTicksOnYourOwnItemsOnly() {
        let task = item(.once), link = item(.link), goal = item(.goal)
        let video = item(.link, source: .extensionYouTube)
        let r = make([
            tick(task, "2026-11-09"), tick(link, "2026-11-15"),
            tick(goal, "2026-11-12"), tick(goal, "2026-11-12"), tick(goal, "2026-11-13", 3),
            tick(video, "2026-11-10"),                       // a collection item: not "done"
            tick(task, "2026-11-08"), tick(task, "2026-11-16"), // the weeks around it
            tick(task, "2026-11-11", voided: true),          // undone
        ])
        #expect(r?.done == 7)
        #expect(r?.watched == 1 && r?.read == 0)
    }

    @Test func deletedItemsStillCountExceptInHighlightsAndCollections() {
        let gone = item(.habit, "Gone", deleted: true)
        let video = item(.link, source: .extensionYouTube, deleted: true)   // left Watch Later
        let deletedVideo = item(.link, source: .extensionYouTube, deleted: true)
        let r = make([tick(gone, "2026-11-09"), tick(gone, "2026-11-10"), tick(video, "2026-11-11"),
                      tick(deletedVideo, "2026-11-11")],
                     focus: [focus(gone, "2026-11-10", 30)], userDeleted: [deletedVideo.id])
        #expect(r?.done == 2 && r?.focusMinutes == 30)
        #expect(r?.highlights.isEmpty == true)
        #expect(r?.watched == 1)
    }

    @Test func nothingToShowMeansNoRecap() {
        let task = item(.once)
        #expect(make([]) == nil)
        // Focus time alone does not bring the card.
        #expect(make([], focus: [focus(task, "2026-11-10", 50)]) == nil)
        // Only a tick on a list that is off, or on a video the user deleted: nothing shows.
        let video = item(.link, source: .extensionYouTube)
        #expect(make([tick(video, "2026-11-10")], listsOff: [.extensionYouTube]) == nil)
        #expect(make([tick(video, "2026-11-10")], userDeleted: [video.id]) == nil)
        // A post alone is enough.
        let post = item(.link, source: .extensionX)
        #expect(make([tick(post, "2026-11-10")])?.read == 1)
    }

    @Test func aListTurnedOffHasNoNumber() {
        let task = item(.once), post = item(.link, source: .extensionX)
        let r = make([tick(task, "2026-11-10"), tick(post, "2026-11-10")], listsOff: [.extensionX])
        #expect(r?.read == nil && r?.watched == 0 && r?.done == 1)
    }

    @Test func focusCountsTheWeeksLiveSessions() {
        let task = item(.once)
        let r = make([tick(task, "2026-11-10")], focus: [
            focus(task, "2026-11-09", 25), focus(task, "2026-11-15", 60),
            focus(task, "2026-11-08", 90), focus(task, "2026-11-16", 90),   // the weeks around it
            focus(task, "2026-11-10", 45, voided: true),
        ])
        #expect(r?.focusMinutes == 85)
    }

    @Test func highlightsAreHabitsAndGoalsTickedTwiceOrMoreMostFirstAtMostTwo() {
        let a = item(.habit, "A", sortKey: 3), b = item(.goal, "B", sortKey: 2), c = item(.habit, "C", sortKey: 1)
        let once = item(.once, "Once")
        let single = item(.habit, "Single", sortKey: 0)
        let r = make([
            tick(a, "2026-11-09"), tick(a, "2026-11-10"),                       // 2
            tick(b, "2026-11-10", 4),                                           // 4 (+1s)
            tick(c, "2026-11-11"), tick(c, "2026-11-12"),                       // 2, earlier in the list
            tick(once, "2026-11-09"), tick(once, "2026-11-10"), tick(once, "2026-11-11"),  // not a habit or goal
            tick(single, "2026-11-09"),                                         // once: not a highlight
        ])
        #expect(r?.highlights.map(\.title) == ["B", "C"])
        #expect(r?.highlights.map(\.count) == [4, 2])
    }

    @Test func oneTickIsNoHighlightAndTiesFollowTheListNotTheId() {
        // The ids sort the other way round from the list, so only the list order can win.
        func habit(_ title: String, sortKey: Double, id: String) -> Item {
            Item(id: UUID(uuidString: id)!, kind: .habit, title: title, schedule: .daily, progress: .none,
                 state: .active, sortKey: sortKey, source: .user, createdAt: t0, updatedAt: t0)
        }
        let first = habit("First", sortKey: 1, id: "FFFFFFFF-0000-0000-0000-000000000000")
        let second = habit("Second", sortKey: 2, id: "00000000-0000-0000-0000-000000000000")
        let once = habit("Once", sortKey: 0, id: "11111111-0000-0000-0000-000000000000")
        let r = make([tick(second, "2026-11-09"), tick(second, "2026-11-10"),
                      tick(first, "2026-11-09"), tick(first, "2026-11-10"), tick(once, "2026-11-11")])
        #expect(r?.highlights.map(\.title) == ["First", "Second"])
        let alone = make([tick(first, "2026-11-09"), tick(first, "2026-11-10"), tick(once, "2026-11-11")])
        #expect(alone?.highlights.map(\.title) == ["First"])
        // Same sort key: the older item first, as in the list (ids the other way round).
        func made(_ title: String, at: Double, id: String) -> Item {
            Item(id: UUID(uuidString: id)!, kind: .goal, title: title, schedule: .daily, progress: .counter(target: 9),
                 state: .active, sortKey: 5, source: .user, createdAt: t0.addingTimeInterval(at), updatedAt: t0)
        }
        let older = made("Older", at: 0, id: "FFFFFFFF-0000-0000-0000-000000000001")
        let newer = made("Newer", at: 60, id: "00000000-0000-0000-0000-000000000001")
        #expect(make([tick(newer, "2026-11-09", 2), tick(older, "2026-11-09", 2)])?.highlights.map(\.title)
                == ["Older", "Newer"])
    }
}
