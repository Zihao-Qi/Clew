import ClewDomain
import Foundation

/// An event from macOS Calendar, read live for the day timeline (SPEC 2026-11-10,
/// "Calendar events"). Never stored, exported or sent anywhere; the app's EventKit
/// adapter builds these and skips declined events.
public struct CalendarEvent: Hashable, Sendable, Identifiable {
    public let id: String
    public let calendarId: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// The calendar's colour as 0–1 red, green, blue.
    public let color: [Double]

    public init(id: String, calendarId: String, title: String, start: Date, end: Date, isAllDay: Bool,
                color: [Double]) {
        self.id = id
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.color = color
    }
}

/// A calendar the user can show or hide in Settings › Calendar.
public struct CalendarInfo: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let source: String
    public let color: [Double]

    public init(id: String, title: String, source: String, color: [Double]) {
        self.id = id
        self.title = title
        self.source = source
        self.color = color
    }
}

/// Where a block or an event sits: its column among those it overlaps.
public struct TimelinePlace: Hashable, Sendable {
    public let lane: Int
    public let lanes: Int

    public init(lane: Int, lanes: Int) {
        self.lane = lane
        self.lanes = lanes
    }
}

/// Today's events, laid out with the blocks.
public struct TimelineEvents: Hashable, Sendable {
    /// Timed events, cut to the day, by start.
    public let timed: [CalendarEvent]
    /// All-day events: a thin line at the top of the timeline.
    public let allDay: [CalendarEvent]
    /// Columns for every block (by block id) and timed event (by event id), together, so a
    /// block and an event at the same time sit side by side.
    public let blockPlaces: [UUID: TimelinePlace]
    public let eventPlaces: [String: TimelinePlace]
}

extension Clew {
    static let calendarShownKey = "calendarShown"
    static let calendarPromptKey = "calendarPromptClosed"
    static let calendarsHiddenKey = "calendarsHidden"

    /// Events of the hidden calendars left out, all-day ones apart, timed ones cut to
    /// Clew's day (4 a.m. to 4 a.m.), and one layout for blocks and events together.
    public static func timelineEvents(_ events: [CalendarEvent], day: TimelineDay,
                                      hidden: Set<String>) -> TimelineEvents {
        let shown = events.filter { !hidden.contains($0.calendarId) && $0.end > day.start && $0.start < day.end }
        let allDay = shown.filter(\.isAllDay).sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        let timed = shown.filter { !$0.isAllDay && $0.end > $0.start }
            .map { e in
                CalendarEvent(id: e.id, calendarId: e.calendarId, title: e.title, start: max(e.start, day.start),
                              end: min(e.end, day.end), isAllDay: false, color: e.color)
            }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        // Blocks and events in one start order; for a tie, blocks first.
        enum Key: Hashable { case block(UUID), event(String) }
        let spans: [(key: Key, start: Date, end: Date, order: Int)] =
            day.blocks.map { (.block($0.id), $0.block.start, $0.block.end, 0) }
            + timed.map { (.event($0.id), $0.start, $0.end, 1) }
        let sorted = spans.sorted { ($0.start, $0.order) < ($1.start, $1.order) }
        let lanes = lanes(sorted.map { ($0.start, $0.end) })
        var blockPlaces: [UUID: TimelinePlace] = [:]
        var eventPlaces: [String: TimelinePlace] = [:]
        for (span, lane) in zip(sorted, lanes) {
            let place = TimelinePlace(lane: lane.lane, lanes: lane.lanes)
            switch span.key {
            case .block(let id): blockPlaces[id] = place
            case .event(let id): eventPlaces[id] = place
            }
        }
        return TimelineEvents(timed: timed, allDay: allDay, blockPlaces: blockPlaces, eventPlaces: eventPlaces)
    }

    // MARK: Settings › Calendar

    /// Calendar events show on the timeline (off until the user turns them on; access is
    /// asked then, never at launch).
    public func calendarShown() throws -> Bool {
        try storeForQueries.read { try $0.setting(Self.calendarShownKey) == "true" }
    }

    public func setCalendarShown(_ on: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.calendarShownKey, json: on ? "true" : "false", updatedAt: now) }
    }

    /// "Show your calendar" on the timeline was closed with ×.
    public func calendarPromptClosed() throws -> Bool {
        try storeForQueries.read { try $0.setting(Self.calendarPromptKey) == "true" }
    }

    public func closeCalendarPrompt() throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.calendarPromptKey, json: "true", updatedAt: now) }
    }

    /// The calendars unticked in Settings. Only these are remembered, so a new calendar
    /// shows by default.
    public func hiddenCalendars() throws -> Set<String> {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.calendarsHiddenKey),
                  let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
            return Set(ids)
        }
    }

    public func setCalendar(_ id: String, hidden: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            var ids: Set<String> = []
            if let json = try w.setting(Self.calendarsHiddenKey),
               let stored = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) { ids = Set(stored) }
            if hidden { ids.insert(id) } else { ids.remove(id) }
            let json = String(decoding: try JSONEncoder().encode(ids.sorted()), as: UTF8.self)
            try w.saveSetting(Self.calendarsHiddenKey, json: json, updatedAt: now)
        }
    }
}
