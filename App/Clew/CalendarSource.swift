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
}

enum CalendarAccess { case notAsked, granted, denied }

/// macOS Calendar through EventKit, read only (SPEC 2026-11-10, "Calendar events"):
/// Clew never writes to a calendar, and events are read live, never stored. macOS 14 has
/// no read-only access, so this asks for full access; the prompt's text says Clew only reads.
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
            let id = (e.calendarItemIdentifier) + "@" + String(Int(start.timeIntervalSince1970))
            return CalendarEvent(id: id, calendarId: e.calendar.calendarIdentifier, title: e.title ?? "",
                                 start: start, end: end, isAllDay: e.isAllDay, color: Self.rgb(e.calendar.cgColor))
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
