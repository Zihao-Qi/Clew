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

    /// SPEC 2026-11-13: the double-click's name box sits in the column its block will get,
    /// so nothing moves on Return.
    @Test func theNameBoxTakesTheColumnItsBlockWillGet() throws {
        let first = try clew.placeOnTimeline(itemId: try clew.addItem(NewItem(title: "a", shape: .today)).id,
                                             start: at(10, 10))
        let events = [event("call", at(10, 10), at(10, 11)), event("lunch", at(10, 12), at(10, 13))]
        // Same start as a block and an event; and over an event alone. Each placing comes
        // later than the one before, as on a real clock (ties of `placedAt` go by id).
        for (i, start) in [at(10, 10), at(10, 12, 15)].enumerated() {
            clock.set(at(10, 9).addingTimeInterval(Double(i + 1)))
            let before = try clew.timeline()
            let timed = Clew.timelineEvents(events, day: before, hidden: []).timed
            let box = Clew.timelineLayout(blocks: before.blocks, timed: timed,
                                          draft: (start, start.addingTimeInterval(30 * 60)))
            let made = try clew.addOnTimeline(title: "new", start: start)
            let after = Clew.timelineEvents(events, day: try clew.timeline(), hidden: [])
            #expect(box.draft == after.blockPlaces[made.block.id])
            // Everything else is already where it will be.
            #expect(box.blocks[first.id] == after.blockPlaces[first.id] && box.events == after.eventPlaces)
            try clew.removeBlock(id: made.block.id)
        }
        // Without calendar events, the box matches the block's own lane.
        let before = try clew.timeline()
        let box = Clew.timelineLayout(blocks: before.blocks, timed: [], draft: (at(10, 10), at(10, 10, 30)))
        clock.set(at(10, 9).addingTimeInterval(10))
        let made = try clew.addOnTimeline(title: "solo", start: at(10, 10))
        let placed = try #require(try clew.timeline().blocks.first { $0.id == made.block.id })
        #expect(box.draft == TimelinePlace(lane: placed.lane, lanes: placed.lanes))
        #expect(box.draft == TimelinePlace(lane: 1, lanes: 2))
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

/// SPEC 2026-11-19, "Editing an event".
@Suite struct EventEditTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    private func editable(_ id: String, _ start: Date, _ end: Date) -> CalendarEvent {
        CalendarEvent(id: id, calendarId: "work", title: id, start: start, end: end, isAllDay: false,
                      color: [0, 0.5, 1], canEdit: true, repeats: true)
    }

    @Test func onlyAnEventInsideTheDayCanBeChangedThere() throws {
        let day = try clew.timeline()
        let layout = Clew.timelineEvents([
            editable("inside", at(10, 9), at(10, 10)),
            editable("early", at(10, 2), at(10, 5)),                    // began before 4 a.m.
            editable("late", at(11, 3), at(11, 5)),                     // runs past 4 a.m.
            editable("edges", at(10, 4), at(11, 4)),                    // exactly the day
            event("readOnly", at(10, 11), at(10, 12)),
        ], day: day, hidden: [])
        let canEdit = Dictionary(uniqueKeysWithValues: layout.timed.map { ($0.id, $0.canEdit) })
        #expect(canEdit == ["inside": true, "early": false, "late": false, "edges": true, "readOnly": false])
        #expect(layout.timed.allSatisfy { $0.id == "readOnly" ? !$0.repeats : $0.repeats })
    }

    @Test func aMoveIsWholeQuarterHoursKeepingTheLengthInsideTheDay() throws {
        let day = try clew.timeline()
        let e = editable("call", at(10, 9, 5), at(10, 9, 55))          // 50 minutes, off the grid
        #expect(Clew.movedEvent(e, by: 7, day: day) == (at(10, 9, 5), at(10, 9, 55)))
        #expect(Clew.movedEvent(e, by: 8, day: day) == (at(10, 9, 20), at(10, 10, 10)))
        #expect(Clew.movedEvent(e, by: -38, day: day) == (at(10, 8, 20), at(10, 9, 10)))
        // Kept inside 4 a.m. to 4 a.m.
        #expect(Clew.movedEvent(e, by: -600, day: day) == (at(10, 4), at(10, 4, 50)))
        #expect(Clew.movedEvent(e, by: 2000, day: day) == (at(11, 3, 10), at(11, 4)))
    }

    @Test func theBottomEdgeMovesTheEndByQuarterHours() throws {
        let day = try clew.timeline()
        let e = editable("call", at(10, 9), at(10, 9, 50))
        #expect(Clew.resizedEnd(e, by: 7, day: day) == at(10, 9, 50))
        #expect(Clew.resizedEnd(e, by: 8, day: day) == at(10, 10, 5))
        #expect(Clew.resizedEnd(e, by: -30, day: day) == at(10, 9, 20))
        // At least 15 minutes.
        #expect(Clew.resizedEnd(e, by: -300, day: day) == at(10, 9, 15))
        // At most the day's end.
        #expect(Clew.resizedEnd(e, by: 3000, day: day) == at(11, 4))
        // A 10-minute event never grows by being made shorter.
        let short = editable("short", at(10, 9), at(10, 9, 10))
        #expect(Clew.resizedEnd(short, by: -15, day: day) == at(10, 9, 10))
        #expect(Clew.resizedEnd(short, by: 15, day: day) == at(10, 9, 25))
    }

    @Test func thePageRefusesAnEmptyTitleOrAnEndNotAfterTheStart() {
        #expect(Clew.eventEditProblem(title: "Call", start: at(10, 9), end: at(10, 9, 1)) == nil)
        #expect(Clew.eventEditProblem(title: " \n", start: at(10, 9), end: at(10, 10)) == .noTitle)
        #expect(Clew.eventEditProblem(title: "Call", start: at(10, 9), end: at(10, 9)) == .endsBeforeStart)
        #expect(Clew.eventEditProblem(title: "Call", start: at(10, 9), end: at(10, 8)) == .endsBeforeStart)
    }
}
