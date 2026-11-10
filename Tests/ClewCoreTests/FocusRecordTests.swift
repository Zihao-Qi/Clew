import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ d: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m, second: s))!
}

/// SPEC decision 2026-11-10, step 2: focus time is recorded (optional in Settings) and
/// can be added by hand; a task's details show it.
@Suite struct FocusRecordTests {
    let store = FakeStore()
    let clock = TestClock(local(10, 10))   // Tuesday
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    private func task() throws -> UUID { try clew.addItem(NewItem(title: "write", shape: .today)).id }
    private var sessions: [FocusSession] { store.state.focusSessions.values.sorted { $0.at < $1.at } }

    @Test func stoppingAFocusRecordsItsRealMinutes() throws {
        let id = try task()
        try clew.startFocus(itemId: id, minutes: 25)
        clock.set(local(10, 10, 5)); try clew.pauseFocus()
        clock.set(local(10, 10, 20)); try clew.resumeFocus()       // 15 minutes paused
        clock.set(local(10, 10, 27, 20)); try clew.stopFocus()      // 12 min 20 s counted
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.itemId == id && s.minutes == 12 && s.kind == .timer && s.voidedAt == nil)
        #expect(s.at == local(10, 10) && s.localDay == LocalDay(string: "2026-11-10")!)
    }

    @Test func aFocusCountsForTheDayItStarted() throws {
        // Days roll over at 4 a.m.: started at 3:40 on the 11th is still the 10th.
        let id = try task()
        clock.set(local(11, 3, 40)); try clew.startFocus(itemId: id, minutes: 45)
        clock.set(local(11, 4, 20)); try clew.stopFocus()
        #expect(sessions.map(\.localDay) == [LocalDay(string: "2026-11-10")!])
    }

    @Test func aTimerOnATaskThatIsDeletedSavesNothing() throws {
        // Its details are gone, so there is nowhere to show the time (Gemini review).
        let id = try task()
        try clew.startFocus(itemId: id, minutes: 10)
        clock.set(local(10, 10, 8)); try clew.deleteItem(itemId: id)
        try clew.stopFocus()
        #expect(sessions.isEmpty)
    }

    @Test func beforeTheRolloverTodaysCalendarDateIsStillTheFuture() throws {
        // At 2 a.m. on the 11th, Clew's day is the 10th: the 11th cannot get time yet.
        let id = try task()
        clock.set(local(11, 2))
        #expect(throws: ClewError.notAllowed) { try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-11")!, minutes: 10) }
        try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 10)
    }

    @Test func doneRecordsTheWholeFocus() throws {
        let id = try task()
        try clew.startFocus(itemId: id, minutes: 10)
        clock.set(local(10, 10, 12)); try clew.finishFocus()        // 2 minutes over
        #expect(sessions.map(\.minutes) == [12])
    }

    @Test func breaksAndMomentsAreNotRecorded() throws {
        let id = try task()
        try clew.startFocus(itemId: id, minutes: 10)
        clock.set(local(10, 10, 0, 29)); try clew.stopFocus()       // under half a minute
        #expect(sessions.isEmpty)
        try clew.startFocus(itemId: id, minutes: 10)
        clock.set(local(10, 10, 11)); try clew.startBreak()         // the focus ends: recorded...
        clock.set(local(10, 10, 16)); try clew.stopFocus()          // ...the break is never time worked
        #expect(sessions.map(\.minutes) == [11])
    }

    @Test func recordingCanBeTurnedOffButAddingByHandStays() throws {
        let id = try task()
        #expect(try clew.focusRecordsTime())
        try clew.setFocusRecordsTime(false)
        #expect(try !clew.focusRecordsTime())
        try clew.startFocus(itemId: id, minutes: 10)
        clock.set(local(10, 10, 10)); try clew.stopFocus()
        #expect(sessions.isEmpty)
        try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-09")!, minutes: 30)
        #expect(sessions.map(\.kind) == [.manual])
    }

    @Test func addingTimeByHandIsChecked() throws {
        let id = try task()
        let s = try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-08")!, minutes: 45)
        #expect(s.kind == .manual && s.minutes == 45 && s.at == local(10, 10) && s.localDay == LocalDay(string: "2026-11-08")!)
        #expect(throws: ClewError.invalidMinutes(max: 720)) { try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 0) }
        #expect(throws: ClewError.invalidMinutes(max: 720)) { try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 721) }
        #expect(throws: ClewError.notAllowed) { try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-11")!, minutes: 10) }
        try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 720)    // today, the most
        try clew.importExternal(ImportBatch(source: .extensionYouTube,
            entries: [ExternalEntry(externalRef: "aaaaaaaaaaa", title: "v")], listTotal: 1))
        let video = try #require(store.state.items.values.first { $0.externalRef == "aaaaaaaaaaa" }).id
        #expect(throws: ClewError.notAllowed) { try clew.addFocusTime(itemId: video, day: LocalDay(string: "2026-11-10")!, minutes: 10) }
        try clew.deleteItem(itemId: id)
        #expect(throws: ClewError.itemNotFound) { try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 10) }
        #expect(sessions.count == 2)
    }

    @Test func removingASessionVoidsIt() throws {
        let id = try task()
        let s = try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 20)
        clock.set(local(10, 11)); try clew.removeFocusSession(id: s.id)
        #expect(store.state.focusSessions[s.id]?.voidedAt == local(10, 11))
        try clew.removeFocusSession(id: s.id)                       // again: nothing changes
        #expect(store.state.focusSessions[s.id]?.voidedAt == local(10, 11))
        #expect(throws: ClewError.notAllowed) { try clew.removeFocusSession(id: UUID()) }
        #expect(try clew.focusSummary(itemId: id) == FocusSummary(thisWeek: 0, total: 0, recent: []))
    }

    @Test func theSummaryCountsThisWeekAndAllTime() throws {
        let id = try task()
        let monday = try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-09")!, minutes: 25)
        let lastWeek = try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-05")!, minutes: 40)
        clock.set(local(10, 12))
        let today = try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 10)
        var summary = try clew.focusSummary(itemId: id)
        #expect(summary.thisWeek == 35 && summary.total == 75)
        #expect(summary.recent.map(\.id) == [today.id, monday.id, lastWeek.id])           // newest day first
        #expect(try clew.focusSummary(itemId: id, recent: 2).recent.count == 2)
        // The clock moving back hides days after today, as the heatmap does.
        clock.set(local(9, 12))
        summary = try clew.focusSummary(itemId: id)
        #expect(summary.total == 65 && summary.recent.map(\.id) == [monday.id, lastWeek.id])
        // Another task's time is not this one's.
        let other = try task()
        try clew.addFocusTime(itemId: other, day: LocalDay(string: "2026-11-09")!, minutes: 5)
        #expect(try clew.focusSummary(itemId: id).total == 65)
    }

    @Test func sessionsAreExported() throws {
        let id = try task()
        try clew.addFocusTime(itemId: id, day: LocalDay(string: "2026-11-10")!, minutes: 30)
        let records = try store.read { try $0.allRecords() }
        #expect(records.focusSessions.map(\.minutes) == [30])
    }
}
