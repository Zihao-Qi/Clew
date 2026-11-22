#if DEBUG
import AppKit
import ClewCore
import EventKit
import Foundation

extension Snapshot {
    /// `CLEW_EVENTKIT_UNDO_TEST=1`: the real Calendar. Makes a calendar "Clew test
    /// (temporary)" in On My Mac (or in iCloud with `CLEW_EVENTKIT_UNDO_SOURCE=icloud`; any
    /// other value is refused, and so is a missing source), a daily event five times from
    /// tomorrow, then changes the third with "All future events" and undoes it as the app
    /// does, and the same with "This event only"; then removes the calendar. Prints
    /// PASS/FAIL. Run only with the user's say-so (2026-11-21: On My Mac, passed).
    static func startEventUndoCheck() {
        Task { @MainActor in
            var failures = 0
            @MainActor func report(_ name: String, _ ok: Bool) {
                if !ok { failures += 1 }
                print(ok ? "PASS" : "FAIL", name); fflush(stdout)
            }
            let source = EventKitCalendar()
            if source.access != .granted { _ = await source.requestAccess() }
            guard source.access == .granted else { print("FAIL: no calendar access"); exit(1) }
            let store = source.storeForCheck
            // CLEW_EVENTKIT_UNDO_SOURCE=icloud: in iCloud instead (the user's choice,
            // 2026-11-21), where the server may rewrite a split series.
            let asked = ProcessInfo.processInfo.environment["CLEW_EVENTKIT_UNDO_SOURCE"]
            guard asked == nil || asked == "icloud" else { print("FAIL: unknown source \(asked!); nothing was made"); exit(1) }
            let wantsICloud = asked == "icloud"
            guard let local = wantsICloud
                    ? store.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
                    : store.sources.first(where: { $0.sourceType == .local }) else {
                print("FAIL: no \(wantsICloud ? "iCloud" : "On My Mac") calendars here; nothing was made. Sources:",
                      store.sources.map { "\($0.title) (\($0.sourceType.rawValue))" })
                exit(1)
            }
            print("  in:", local.title)
            /// A server's calendar settles after a save: give it time, as a person would
            /// take a few seconds before Undo.
            @MainActor func settle() async {
                guard wantsICloud else { return }
                try? await Task.sleep(for: .seconds(5))
                store.refreshSourcesIfNecessary()
                try? await Task.sleep(for: .seconds(1))
            }
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = "Clew test (temporary)"
            calendar.source = local
            do { try store.saveCalendar(calendar, commit: true) } catch { print("FAIL: calendar not made:", error); exit(1) }
            let calendarId = calendar.calendarIdentifier
            @MainActor func cleanUp() {
                // Found again by its id: a refused save resets the store and its objects.
                guard let made = store.calendar(withIdentifier: calendarId) else {
                    print("COULD NOT FIND the test calendar to remove it:", calendarId); return
                }
                do { try store.removeCalendar(made, commit: true); print("removed the test calendar") }
                catch { print("COULD NOT REMOVE the test calendar:", error) }
            }
            let cal = Calendar.current
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
            func at(_ day: Int, _ hour: Int) -> Date {
                cal.date(byAdding: .hour, value: hour, to: cal.date(byAdding: .day, value: day, to: tomorrow)!)!
            }
            let e = EKEvent(eventStore: store)
            e.calendar = calendar
            e.title = "Clew undo test"
            e.startDate = at(0, 10)
            e.endDate = at(0, 10).addingTimeInterval(1800)
            e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5)))
            do { try store.save(e, span: .futureEvents, commit: true) } catch { print("FAIL: event not made:", error); cleanUp(); exit(1) }
            let original = e.calendarItemIdentifier
            await settle()

            /// Ours, as Clew reads them: the hour each of the five days starts at.
            /// One event a day, or -1 (none) / -2 (more than one: a split that doubled one).
            @MainActor func hours() -> [Int] {
                (0..<5).map { d in
                    let ours = source.events(from: at(d, 0), to: at(d, 24)).filter { $0.calendarId == calendarId }
                    guard ours.count == 1, let one = ours.first else { return ours.isEmpty ? -1 : -2 }
                    return cal.component(.hour, from: one.start)
                }
            }
            @MainActor func occurrence(_ d: Int) -> CalendarEvent? {
                source.events(from: at(d, 0), to: at(d, 24)).first { $0.calendarId == calendar.calendarIdentifier }
            }
            report("five daily events at 10", hours() == [10, 10, 10, 10, 10])

            // All future events from the third: 11:00, then Undo (the app's way: the id
            // the change returned, back to the old times, the same choice).
            if let third = occurrence(2) {
                let id = source.change(third, title: third.title, start: at(2, 11), end: at(2, 11).addingTimeInterval(1800),
                                       span: .futureEvents)
                print("  series before:", original, "after:", id ?? "nil")
                report("the change split the series (a new series id)", id.map { !$0.hasPrefix(original) } == true)
                await settle()
                report("all future events moves the third and after", id != nil && hours() == [10, 10, 11, 11, 11])
                if let id {
                    let now = CalendarEvent(id: id, calendarId: third.calendarId, title: third.title, start: at(2, 11),
                                            end: at(2, 11).addingTimeInterval(1800), isAllDay: false, color: third.color,
                                            canEdit: true, repeats: true)
                    let back = source.change(now, title: third.title, start: third.start, end: third.end, span: .futureEvents)
                    await settle()
                    report("Undo finds it and puts them back (\(back == nil ? "not found" : "found"))",
                           back != nil && hours() == [10, 10, 10, 10, 10])
                }
            } else {
                report("the third is read", false)
            }
            // This event only, on the fourth: 12:00, then Undo.
            if let fourth = occurrence(3) {
                let id = source.change(fourth, title: fourth.title, start: at(3, 12), end: at(3, 12).addingTimeInterval(1800),
                                       span: .thisEvent)
                await settle()
                report("this event only moves just the fourth", id != nil && hours() == [10, 10, 10, 12, 10])
                if let id {
                    let now = CalendarEvent(id: id, calendarId: fourth.calendarId, title: fourth.title, start: at(3, 12),
                                            end: at(3, 12).addingTimeInterval(1800), isAllDay: false, color: fourth.color,
                                            canEdit: true, repeats: true)
                    let back = source.change(now, title: fourth.title, start: fourth.start, end: fourth.end, span: .thisEvent)
                    await settle()
                    report("Undo puts it back", back != nil && hours() == [10, 10, 10, 10, 10])
                }
            } else {
                report("the fourth is read", false)
            }
            cleanUp()
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
