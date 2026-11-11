import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

private func event(_ id: String, _ start: Date, _ end: Date, calendar: String = "work", allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, calendarId: calendar, title: id, start: start, end: end, isAllDay: allDay, color: [0, 0.5, 1])
}

/// SPEC decision 2026-11-10, day timeline step 2: calendar events, read-only.
@Suite struct CalendarEventTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    @Test func eventsAreCutToClewsDayAndAllDayOnesStandApart() throws {
        let day = try clew.timeline()
        let layout = Clew.timelineEvents([
            event("standup", at(10, 9), at(10, 9, 30)),
            event("late", at(11, 3), at(11, 5)),                       // runs past 4 a.m.
            event("early", at(10, 2), at(10, 5)),                      // began before the day
            event("yesterday", at(9, 10), at(9, 11)),
            event("holiday", at(10, 0), at(11, 0), allDay: true),
            event("hidden", at(10, 11), at(10, 12), calendar: "home"),
        ], day: day, hidden: ["home"])
        #expect(layout.timed.map(\.id) == ["early", "standup", "late"])
        #expect(layout.timed.first?.start == at(10, 4) && layout.timed.last?.end == at(11, 4))
        #expect(layout.allDay.map(\.id) == ["holiday"])
    }

    @Test func blocksAndEventsShareColumnsWhenTheyOverlap() throws {
        let task = try clew.addItem(NewItem(title: "write", shape: .today)).id
        let block = try clew.placeOnTimeline(itemId: task, start: at(10, 10))
        let day = try clew.timeline()
        let layout = Clew.timelineEvents([event("call", at(10, 10, 15), at(10, 11)), event("lunch", at(10, 12), at(10, 13))],
                                         day: day, hidden: [])
        #expect(layout.blockPlaces[block.id] == TimelinePlace(lane: 0, lanes: 2))
        #expect(layout.eventPlaces["call"] == TimelinePlace(lane: 1, lanes: 2))
        #expect(layout.eventPlaces["lunch"] == TimelinePlace(lane: 0, lanes: 1))
    }

    @Test func calendarEventsAreOffUntilTurnedOnAndNewCalendarsShow() throws {
        #expect(try !clew.calendarShown() && !clew.calendarPromptClosed())
        try clew.setCalendarShown(true)
        try clew.closeCalendarPrompt()
        #expect(try clew.calendarShown() && clew.calendarPromptClosed())
        try clew.setCalendar("home", hidden: true)
        try clew.setCalendar("gym", hidden: true)
        try clew.setCalendar("gym", hidden: false)
        // Only the unticked ones are kept: any calendar not listed shows.
        #expect(try clew.hiddenCalendars() == ["home"])
        // Nothing about events is ever written.
        #expect(store.state.settings.keys.sorted() == ["calendarPromptClosed", "calendarShown", "calendarsHidden"])
    }
}
