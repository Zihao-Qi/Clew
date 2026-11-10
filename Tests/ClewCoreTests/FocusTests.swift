import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: h, minute: m, second: s))!
}

/// SPEC decision 2026-11-10: a focus timer on a task, 10/25/45 minutes, a 5-minute
/// break, never ticking by itself, surviving quit.
@Suite struct FocusTests {
    let store = FakeStore()
    let clock = TestClock(local(10))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    private func task(_ title: String = "write") throws -> UUID {
        try clew.addItem(NewItem(title: title, shape: .today)).id
    }

    @Test func startsOnATaskOnTodayForAFixedLength() throws {
        let id = try task()
        let t = try clew.startFocus(itemId: id, minutes: 25)
        #expect(t.phase == .focus && t.itemId == id && t.length == 25 * 60 && t.startedAt == local(10))
        #expect(try clew.focusTimer() == t)
        #expect(t.endsAt == local(10, 25))
        try clew.stopFocus()
        #expect(throws: ClewError.notAllowed) { try clew.startFocus(itemId: id, minutes: 20) }
    }

    @Test func onlyTasksOnTodayCanBeFocusedOn() throws {
        let later = try clew.addItem(NewItem(title: "someday", shape: .later)).id
        #expect(throws: ClewError.notAllowed) { try clew.startFocus(itemId: later, minutes: 10) }
        let gone = try task()
        try clew.deleteItem(itemId: gone)
        #expect(throws: ClewError.itemNotFound) { try clew.startFocus(itemId: gone, minutes: 10) }
        try clew.importExternal(ImportBatch(source: .extensionYouTube,
            entries: [ExternalEntry(externalRef: "aaaaaaaaaaa", title: "v")], listTotal: 1))
        let video = try #require(store.state.items.values.first { $0.externalRef == "aaaaaaaaaaa" }).id
        #expect(throws: ClewError.notAllowed) { try clew.startFocus(itemId: video, minutes: 10) }
        // Even one picked onto Today before collections existed.
        try store.write { w in
            var v = try #require(try w.item(id: video))
            v.state = .active
            try w.update(v)
        }
        #expect(throws: ClewError.notAllowed) { try clew.startFocus(itemId: video, minutes: 10) }
        #expect(try clew.focusTimer() == nil)
    }

    @Test func aRunningFocusIsNeverReplacedButABreakIs() throws {
        let a = try task("a"), b = try task("b")
        try clew.startFocus(itemId: a, minutes: 10)
        #expect(throws: ClewError.focusRunning) { try clew.startFocus(itemId: b, minutes: 10) }
        #expect(throws: ClewError.focusRunning) { try clew.startFocus(itemId: a, minutes: 25) }
        try clew.startBreak()
        let t = try clew.startFocus(itemId: b, minutes: 45)
        #expect(t.itemId == b && t.phase == .focus)
    }

    @Test func pausedTimeDoesNotCount() throws {
        try clew.startFocus(itemId: try task(), minutes: 10)
        clock.set(local(10, 4)); try clew.pauseFocus()
        clock.set(local(10, 30))
        var t = try #require(try clew.focusTimer())
        #expect(t.isPaused && t.elapsed(at: local(10, 30)) == 4 * 60 && t.endsAt == nil)
        try clew.pauseFocus()                                        // twice changes nothing
        try clew.resumeFocus()
        t = try #require(try clew.focusTimer())
        #expect(!t.isPaused && t.pausedFor == 26 * 60 && t.endsAt == local(10, 36))
        #expect(t.remaining(at: local(10, 32)) == 4 * 60 && t.fraction(at: local(10, 31)) == 0.5)
        try clew.resumeFocus()                                       // not paused: nothing
        #expect(try clew.focusTimer() == t)
    }

    @Test func fiveMoreMinutesCountFromNowWhenTimeIsUp() throws {
        try clew.startFocus(itemId: try task(), minutes: 10)
        clock.set(local(10, 5)); try clew.extendFocus()             // not up yet: 15 in all
        #expect(try clew.focusTimer()?.length == 15 * 60)
        clock.set(local(10, 22)); try clew.extendFocus()            // up 7 min ago: ends at 10:27
        let t = try #require(try clew.focusTimer())
        #expect(t.endsAt == local(10, 27) && !t.isOver(at: local(10, 26)) && t.isOver(at: local(10, 27)))
    }

    @Test func aBreakFollowsAFocusOnlyWhenOffered() throws {
        let id = try task()
        #expect(throws: ClewError.notAllowed) { try clew.startBreak() }   // nothing running
        #expect(try clew.focusOffersBreak())
        try clew.startFocus(itemId: id, minutes: 10)
        clock.set(local(10, 10)); try clew.startBreak()
        let t = try #require(try clew.focusTimer())
        #expect(t.phase == .rest && t.itemId == id && t.length == 5 * 60 && t.startedAt == local(10, 10))
        #expect(throws: ClewError.notAllowed) { try clew.startBreak() }   // not from a break
        try clew.stopFocus()
        try clew.setFocusOffersBreak(false)
        #expect(try !clew.focusOffersBreak())
        try clew.startFocus(itemId: id, minutes: 10)
        #expect(throws: ClewError.notAllowed) { try clew.startBreak() }
    }

    @Test func stopEndsItAndSaysWhatRan() throws {
        #expect(try clew.stopFocus() == nil)
        let started = try clew.startFocus(itemId: try task(), minutes: 25)
        #expect(try clew.stopFocus() == started)
        #expect(try clew.focusTimer() == nil)
    }

    @Test func itSurvivesQuittingAndNeverTicks() throws {
        let id = try task()
        try clew.startFocus(itemId: id, minutes: 10)
        clock.set(local(11))                                         // long over, app reopened
        let reopened = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
        #expect(try reopened.focusTimer()?.isOver(at: local(11)) == true)
        #expect(store.state.checkIns.isEmpty)
    }

    @Test func theClockMovingBackNeverGivesNegativeTime() throws {
        try clew.startFocus(itemId: try task(), minutes: 10)
        let t = try #require(try clew.focusTimer())
        #expect(t.elapsed(at: local(9)) == 0 && t.remaining(at: local(9)) == 10 * 60 && t.fraction(at: local(9)) == 0)
    }

    @Test func anUnreadableTimerIsNoTimer() throws {
        try store.write { try $0.saveSetting("focusTimer", json: #"{"phase":"nap"}"#, updatedAt: local(10)) }
        #expect(try clew.focusTimer() == nil)
    }

    @Test func theEndIsNotifiedFirstUnlessPausedOrOver() throws {
        let id = try task("write the essay")
        try clew.setReminder(itemId: id, time: TimeOfDay(hour: 18, minute: 0))
        try clew.startFocus(itemId: id, minutes: 25)
        var plan = try clew.plannedNotifications()
        #expect(plan.first == PlannedNotification(id: "clew.focus", fireAt: local(10, 25),
                                                  content: .focusEnded(itemId: id, title: "write the essay")))
        #expect(plan.contains { if case .reminder = $0.content { true } else { false } })
        try clew.pauseFocus()
        #expect(try clew.plannedNotifications().allSatisfy { $0.id != "clew.focus" })
        try clew.resumeFocus()
        clock.set(local(10, 30))                                     // over: nothing left to say
        #expect(try clew.plannedNotifications().allSatisfy { $0.id != "clew.focus" })
        try clew.startBreak()
        plan = try clew.plannedNotifications()
        #expect(plan.first?.content == .breakEnded(title: "write the essay") && plan.first?.fireAt == local(10, 35))
    }
}
