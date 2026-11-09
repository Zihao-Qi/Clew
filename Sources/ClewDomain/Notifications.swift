import Foundation

/// A wall-clock time of day, e.g. 09:00.
public struct TimeOfDay: Hashable, Comparable, Sendable, Codable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

/// A gentle reminder (SPEC §6): one notification at `time` on each day the item is on
/// Today's list and not done yet. One per item. A definition: edited, soft-deleted.
public struct Reminder: Hashable, Sendable, Identifiable, Codable {
    public var id: UUID
    public var itemId: UUID
    public var time: TimeOfDay
    public var enabled: Bool
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID, itemId: UUID, time: TimeOfDay, enabled: Bool = true, updatedAt: Date, deletedAt: Date? = nil) {
        self.id = id
        self.itemId = itemId
        self.time = time
        self.enabled = enabled
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Day summaries (SPEC §7): each optional, off until switched on.
public struct SummarySettings: Hashable, Sendable, Codable {
    public var morningEnabled: Bool
    public var morningTime: TimeOfDay
    public var eveningEnabled: Bool
    public var eveningTime: TimeOfDay

    public init(morningEnabled: Bool, morningTime: TimeOfDay, eveningEnabled: Bool, eveningTime: TimeOfDay) {
        self.morningEnabled = morningEnabled
        self.morningTime = morningTime
        self.eveningEnabled = eveningEnabled
        self.eveningTime = eveningTime
    }

    /// SPEC decision: 9:00 and 21:00, off until switched on.
    public static let defaults = SummarySettings(
        morningEnabled: false, morningTime: TimeOfDay(hour: 9, minute: 0)!,
        eveningEnabled: false, eveningTime: TimeOfDay(hour: 21, minute: 0)!
    )
}

extension LocalDay {
    /// The instant `time` happens during this day, in `zone`. A time earlier than the
    /// rollover hour belongs to the end of the day, so it falls on the next calendar
    /// date: a 01:00 reminder on Monday's item fires at Tuesday 01:00 (ARCHITECTURE
    /// §4.3).
    public func instant(at time: TimeOfDay, in zone: TimeZone, rolloverHour: Int) -> Date {
        let date = time.hour < rolloverHour ? adding(days: 1) : self
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: date.year, month: date.month, day: date.day,
                                        hour: time.hour, minute: time.minute)
        // In a DST gap Foundation moves forward by the gap (02:30 → 03:30), which is
        // still that morning.
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
