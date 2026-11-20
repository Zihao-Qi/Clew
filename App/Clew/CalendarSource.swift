import AppKit
import ClewCore
import EventKit
import Foundation

/// Where calendar events come from: macOS Calendar in the app, made-up ones in the
/// debug snapshot.
@MainActor
protocol CalendarReading: AnyObject {
    var access: CalendarAccess { get }
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    func events(from start: Date, to end: Date) -> [CalendarEvent]
    /// Calls `onChange` whenever Calendar's data changes (an event added on the phone…).
    func observe(_ onChange: @escaping @MainActor () -> Void)
    /// Saves a new title and times for `event` (a repeating one: this occurrence, or it and
    /// the ones after). Returns the event's id afterwards (its start, and for "all future
    /// events" its series, may be new), or nil if Calendar refused.
    func change(_ event: CalendarEvent, title: String, start: Date, end: Date, span: EventSpan) -> String?
}

enum CalendarAccess { case notAsked, granted, denied }

/// A repeating event's change: as Calendar asks (SPEC 2026-11-19).
enum EventSpan { case thisEvent, futureEvents }

/// macOS Calendar through EventKit (SPEC 2026-11-10, "Calendar events"): events are read
/// live, never stored, and one is written only when the user changes it on the timeline
/// (SPEC 2026-11-19, "Editing an event"). macOS 14 has no read-only access, so this asks
/// for full access.
@MainActor
final class EventKitCalendar: CalendarReading {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied            // denied, restricted, or write-only (which cannot read)
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func calendars() -> [CalendarInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, color: Self.rgb($0.cgColor)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { e in
            // Declined invitations are hidden.
            if e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined { return nil }
            guard let start = e.startDate, let end = e.endDate else { return nil }
            return CalendarEvent(id: Self.id(e, start: start), calendarId: e.calendar.calendarIdentifier,
                                 title: e.title ?? "", start: start, end: end, isAllDay: e.isAllDay,
                                 color: Self.rgb(e.calendar.cgColor), canEdit: Self.canEdit(e),
                                 repeats: e.hasRecurrenceRules)
        }
    }

    /// One occurrence: its series and its start.
    private static func id(_ e: EKEvent, start: Date) -> String {
        e.calendarItemIdentifier + "@" + String(Int(start.timeIntervalSince1970))
    }

    /// Its calendar allows changes, and it is not someone else's invitation (SPEC 2026-11-19).
    private static func canEdit(_ e: EKEvent) -> Bool {
        guard e.calendar.allowsContentModifications else { return false }
        guard e.hasAttendees, let organizer = e.organizer else { return true }
        return organizer.isCurrentUser
    }

    func change(_ event: CalendarEvent, title: String, start: Date, end: Date, span: EventSpan) -> String? {
        guard access == .granted, let e = occurrence(event) else { return nil }
        guard Self.canEdit(e) else { return nil }
        e.title = title
        e.startDate = start
        e.endDate = end
        do {
            try store.save(e, span: span == .futureEvents ? .futureEvents : .thisEvent, commit: true)
        } catch {
            store.reset()           // the refused change is not kept in memory either
            return nil
        }
        return Self.id(e, start: e.startDate)
    }

    /// The occurrence `event` was read from, by its series and its start.
    private func occurrence(_ event: CalendarEvent) -> EKEvent? {
        let predicate = store.predicateForEvents(withStart: event.start.addingTimeInterval(-1),
                                                 end: event.end.addingTimeInterval(1), calendars: nil)
        return store.events(matching: predicate).first { e in
            e.startDate != nil && Self.id(e, start: e.startDate) == event.id
        }
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in onChange() }
        }
    }

    static func rgb(_ color: CGColor?) -> [Double] {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return [0.5, 0.5, 0.5] }
        return [Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)]
    }

    /// System Settings › Privacy & Security › Calendars.
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
